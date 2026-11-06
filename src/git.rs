//! Plain git repositories over HTTPS as a skill source (D30), for hosts without a Composer
//! registry or GitHub's API. Speaks git's smart HTTP protocol (v0, stateless) itself, so no git
//! binary, hook or filter of the repository ever runs. Versions and refs work as for GitHub; a
//! commit is fetched at depth 1 and every object is checked against its id, from the pinned
//! commit down.

use std::collections::HashMap;
use std::io::Write;
use std::sync::Mutex;

use jiff::{SignedDuration, Timestamp};
use sha1::Sha1;
use sha2::{Digest, Sha256};
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, System, ZipWriter};

use crate::archive::Limits;
use crate::bail;
use crate::error::{Context, Error, IO, MANIFEST, NETWORK, Result};
use crate::github::is_sha;
use crate::http::{Http, redact};
use crate::lock::Dist;
use crate::manifest::{DEFAULT_REF, GitHub, Repository, SkillReq};
use crate::registry::{self, Candidate};
use crate::version::{Constraint, Version};

pub const KIND: &str = "git";
/// Advertisements are small; a repository with tens of thousands of refs stays below this.
const REFS_LIMIT: u64 = 16 << 20;
/// Commits read to find one older than the cooldown on a branch.
const HISTORY: usize = 100;

type Id = [u8; 20];

/// Errors unless `url` is an `https://` repository URL without credentials, query or fragment;
/// tokens belong in auth.json or the credential helper, not in skills.toml.
pub fn check_url(url: &str) -> std::result::Result<(), String> {
    let u = url::Url::parse(url).map_err(|e| format!("invalid git URL {url:?}: {e}"))?;
    if u.scheme() != "https" || u.host_str().is_none() {
        return Err(format!("git URL {url:?} must start with https://"));
    }
    if !u.username().is_empty() || u.password().is_some() || u.query().is_some() || u.fragment().is_some() {
        return Err(format!("git URL {}: no credentials, query or fragment; put tokens in auth.json", redact(&u)));
    }
    if u.path_segments().is_none_or(|s| s.filter(|p| !p.is_empty()).count() < 2) {
        return Err(format!("git URL {url:?} needs at least owner/repo in its path"));
    }
    Ok(())
}

/// The manifest key `add git:<url>` uses: the last two path segments, lowercase, without `.git`.
pub fn name_of(url: &str) -> Option<String> {
    let u = url::Url::parse(url).ok()?;
    // Azure DevOps: https://dev.azure.com/org/project/_git/repo
    let parts: Vec<&str> = u.path_segments()?.filter(|p| !p.is_empty() && *p != "_git").collect();
    let [.., owner, repo] = parts[..] else { return None };
    let name = format!("{owner}/{}", repo.strip_suffix(".git").unwrap_or(repo)).to_lowercase();
    crate::manifest::valid_package_name(&name).then_some(name)
}

pub fn repository(url: &str) -> Repository {
    Repository { name: KIND.into(), url: url.trim_end_matches('/').to_string(), ..Default::default() }
}

/// Reads git's packet lines: `None` at the end, `Some(None)` for a flush or delimiter.
fn pkt<'a>(b: &'a [u8], pos: &mut usize) -> Result<Option<Option<&'a [u8]>>> {
    if *pos >= b.len() {
        return Ok(None);
    }
    let len = b
        .get(*pos..*pos + 4)
        .and_then(|h| std::str::from_utf8(h).ok())
        .and_then(|h| usize::from_str_radix(h, 16).ok())
        .ok_or_else(|| Error::new(NETWORK, "git: malformed packet line"))?;
    if len < 4 {
        *pos += 4;
        return Ok(Some(None));
    }
    let data = b.get(*pos + 4..*pos + len).ok_or_else(|| Error::new(NETWORK, "git: truncated packet line"))?;
    *pos += len;
    Ok(Some(Some(data)))
}

fn pkt_line(out: &mut Vec<u8>, line: &str) {
    out.extend(format!("{:04x}{line}", line.len() + 4).as_bytes());
}

#[derive(Clone, Default)]
struct Remote {
    /// Ref name to the commit it points at, tags peeled.
    refs: HashMap<String, String>,
    caps: Vec<String>,
}

impl Remote {
    fn has(&self, cap: &str) -> bool {
        self.caps.iter().any(|c| c == cap || c.starts_with(&format!("{cap}=")))
    }
}

fn parse_refs(b: &[u8]) -> Result<Remote> {
    let mut pos = 0;
    let first = pkt(b, &mut pos)?.flatten();
    if first.is_none_or(|l| !l.starts_with(b"# service=git-upload-pack")) {
        bail!(NETWORK, "git: not a smart HTTP git server (no service advertisement)");
    }
    let mut r = Remote::default();
    let mut peeled = Vec::new();
    while let Some(line) = pkt(b, &mut pos)? {
        let Some(line) = line else { continue };
        let line = line.strip_suffix(b"\n").unwrap_or(line);
        let (line, caps) = match line.iter().position(|&c| c == 0) {
            Some(i) => (&line[..i], Some(&line[i + 1..])),
            None => (line, None),
        };
        if let Some(c) = caps {
            r.caps = String::from_utf8_lossy(c).split(' ').filter(|c| !c.is_empty()).map(String::from).collect();
        }
        let text = String::from_utf8_lossy(line);
        let Some((sha, name)) = text.split_once(' ') else { continue };
        if !is_sha(sha) || name == "capabilities^{}" {
            continue;
        }
        let sha = sha.to_ascii_lowercase();
        match name.strip_suffix("^{}") {
            Some(tag) => peeled.push((tag.to_string(), sha)),
            None => {
                r.refs.insert(name.to_string(), sha);
            }
        }
    }
    r.refs.extend(peeled);
    Ok(r)
}

/// The advertised refs of `url`, read once per process.
fn remote(http: &Http, url: &str) -> Result<Remote> {
    static SEEN: Mutex<Vec<(String, Remote)>> = Mutex::new(Vec::new());
    if let Some((_, r)) = SEEN.lock().unwrap_or_else(|e| e.into_inner()).iter().find(|(u, _)| u == url) {
        return Ok(r.clone());
    }
    let body = http
        .get(&format!("{url}/info/refs?service=git-upload-pack"), REFS_LIMIT)?
        .ok_or_else(|| Error::new(MANIFEST, format!("git: {url}: repository not found (404)")))?;
    let r = parse_refs(&body).ctx(url)?;
    SEEN.lock().unwrap_or_else(|e| e.into_inner()).push((url.to_string(), r.clone()));
    Ok(r)
}

/// Fetches `want` at depth `depth` and returns the pack. `commits_only` asks the server to leave
/// out trees and blobs, when it supports filters.
fn fetch_pack(http: &Http, r: &Remote, url: &str, want: &str, depth: usize, commits_only: bool, max: u64) -> Result<Vec<u8>> {
    let band = ["side-band-64k", "side-band"].into_iter().find(|c| r.has(c));
    let mut caps: Vec<&str> = band.into_iter().collect();
    caps.extend(["ofs-delta", "shallow", "no-progress"].into_iter().filter(|c| r.has(c)));
    if commits_only {
        caps.push("filter");
    }
    caps.push(concat!("agent=skillcask/", env!("CARGO_PKG_VERSION")));
    let mut body = Vec::new();
    pkt_line(&mut body, &format!("want {want} {}\n", caps.join(" ")));
    if r.has("shallow") {
        pkt_line(&mut body, &format!("deepen {depth}\n"));
    }
    if commits_only {
        pkt_line(&mut body, "filter tree:0\n");
    }
    body.extend(b"0000");
    pkt_line(&mut body, "done\n");
    let resp = http
        .post(&format!("{url}/git-upload-pack"), ("application/x-git-upload-pack-request", &body), max)?
        .ok_or_else(|| Error::new(MANIFEST, format!("git: {url}: repository not found (404)")))?;
    let mut pack = Vec::new();
    let mut pos = 0;
    while let Some(line) = pkt(&resp, &mut pos)? {
        let Some(line) = line else { continue };
        if let Some(msg) = line.strip_prefix(b"ERR ") {
            bail!(NETWORK, "git: {url}: {}", String::from_utf8_lossy(msg).trim());
        }
        if [&b"shallow "[..], b"unshallow ", b"ACK ", b"NAK"].iter().any(|p| line.starts_with(p)) {
            if band.is_none() && line.starts_with(b"NAK") {
                // Without side-band the pack follows the NAK as it is.
                return Ok(resp[pos..].to_vec());
            }
            continue;
        }
        match line.split_first() {
            Some((1, data)) => pack.extend_from_slice(data),
            Some((2, _)) => {}
            Some((3, msg)) => bail!(NETWORK, "git: {url}: {}", String::from_utf8_lossy(msg).trim()),
            _ => bail!(NETWORK, "git: {url}: unexpected response line"),
        }
    }
    Ok(pack)
}

fn inflate(input: &[u8], size: usize) -> Result<(Vec<u8>, usize)> {
    let corrupt = || Error::new(NETWORK, "git: corrupt pack object");
    let mut d = flate2::Decompress::new(true);
    let mut out = Vec::with_capacity(size + 1);
    loop {
        let (before_in, before_out) = (d.total_in(), d.total_out());
        let rest = input.get(d.total_in() as usize..).ok_or_else(corrupt)?;
        let status = d.decompress_vec(rest, &mut out, flate2::FlushDecompress::None).map_err(|_| corrupt())?;
        if out.len() > size {
            return Err(corrupt());
        }
        match status {
            flate2::Status::StreamEnd => break,
            _ if d.total_in() == before_in && d.total_out() == before_out => return Err(corrupt()),
            _ => {}
        }
    }
    if out.len() != size {
        return Err(corrupt());
    }
    Ok((out, d.total_in() as usize))
}

fn varint(b: &[u8], pos: &mut usize) -> Result<usize> {
    let (mut n, mut shift) = (0usize, 0);
    loop {
        let c = *b.get(*pos).ok_or_else(|| Error::new(NETWORK, "git: corrupt delta"))?;
        *pos += 1;
        n |= ((c & 0x7f) as usize).checked_shl(shift).filter(|_| shift < 63).ok_or_else(|| Error::new(NETWORK, "git: corrupt delta"))?;
        shift += 7;
        if c & 0x80 == 0 {
            return Ok(n);
        }
    }
}

fn apply_delta(base: &[u8], delta: &[u8]) -> Result<Vec<u8>> {
    let bad = || Error::new(NETWORK, "git: corrupt delta");
    let mut pos = 0;
    if varint(delta, &mut pos)? != base.len() {
        return Err(bad());
    }
    let size = varint(delta, &mut pos)?;
    let mut out = Vec::with_capacity(size);
    while pos < delta.len() {
        let op = delta[pos];
        pos += 1;
        if op & 0x80 != 0 {
            let mut field = |bits: std::ops::Range<u8>| -> Result<usize> {
                let mut v = 0usize;
                for (i, bit) in bits.enumerate() {
                    if op & (1 << bit) != 0 {
                        v |= (*delta.get(pos).ok_or_else(bad)? as usize) << (8 * i);
                        pos += 1;
                    }
                }
                Ok(v)
            };
            let offset = field(0..4)?;
            let len = match field(4..7)? {
                0 => 0x10000,
                n => n,
            };
            out.extend_from_slice(base.get(offset..offset.checked_add(len).ok_or_else(bad)?).ok_or_else(bad)?);
        } else if op != 0 {
            out.extend_from_slice(delta.get(pos..pos + op as usize).ok_or_else(bad)?);
            pos += op as usize;
        } else {
            return Err(bad());
        }
        if out.len() > size {
            return Err(bad());
        }
    }
    if out.len() != size {
        return Err(bad());
    }
    Ok(out)
}

fn object_id(kind: u8, data: &[u8]) -> Id {
    let name = match kind {
        1 => "commit",
        2 => "tree",
        3 => "blob",
        _ => "tag",
    };
    let mut h = Sha1::new();
    h.update(format!("{name} {}\0", data.len()).as_bytes());
    h.update(data);
    h.finalize().into()
}

/// Every object of a pack by its computed id, so a lookup by id is also a check of the content.
/// `max`: total inflated bytes.
fn parse_pack(p: &[u8], max: u64) -> Result<HashMap<Id, (u8, Vec<u8>)>> {
    let bad = |what: &str| Error::new(NETWORK, format!("git: corrupt pack ({what})"));
    if p.len() < 32 || &p[..4] != b"PACK" || !matches!(u32::from_be_bytes([p[4], p[5], p[6], p[7]]), 2 | 3) {
        return Err(bad("header"));
    }
    let (body, trailer) = p.split_at(p.len() - 20);
    if Sha1::digest(body).as_slice() != trailer {
        return Err(bad("checksum"));
    }
    let count = u32::from_be_bytes([p[8], p[9], p[10], p[11]]) as usize;
    enum Base {
        Ofs(usize),
        Ref(Id),
    }
    let mut raw: Vec<(usize, u8, Vec<u8>, Option<Base>)> = Vec::with_capacity(count.min(1 << 16));
    let (mut pos, mut total) = (12usize, 0u64);
    for _ in 0..count {
        let start = pos;
        let mut c = *body.get(pos).ok_or_else(|| bad("truncated"))?;
        pos += 1;
        let kind = (c >> 4) & 7;
        let (mut size, mut shift) = ((c & 15) as u64, 4);
        while c & 0x80 != 0 {
            c = *body.get(pos).ok_or_else(|| bad("truncated"))?;
            pos += 1;
            size |= ((c & 0x7f) as u64).checked_shl(shift).filter(|_| shift < 57).ok_or_else(|| bad("size"))?;
            shift += 7;
        }
        let base = match kind {
            1..=4 => None,
            6 => {
                let mut c = *body.get(pos).ok_or_else(|| bad("truncated"))?;
                pos += 1;
                let mut ofs = (c & 0x7f) as usize;
                while c & 0x80 != 0 {
                    c = *body.get(pos).ok_or_else(|| bad("truncated"))?;
                    pos += 1;
                    ofs = ofs.checked_add(1).and_then(|o| o.checked_shl(7)).ok_or_else(|| bad("offset"))? | (c & 0x7f) as usize;
                }
                Some(Base::Ofs(start.checked_sub(ofs).ok_or_else(|| bad("offset"))?))
            }
            7 => {
                let id: Id = body.get(pos..pos + 20).ok_or_else(|| bad("truncated"))?.try_into().expect("20 bytes");
                pos += 20;
                Some(Base::Ref(id))
            }
            _ => return Err(bad("object type")),
        };
        total = total.saturating_add(size);
        if total > max {
            bail!(IO, "git: repository content exceeds {max} bytes");
        }
        let (data, used) = inflate(body.get(pos..).ok_or_else(|| bad("truncated"))?, size as usize)?;
        pos += used;
        raw.push((start, kind, data, base));
    }
    let at: HashMap<usize, usize> = raw.iter().enumerate().map(|(i, r)| (r.0, i)).collect();
    let mut done: Vec<Option<(u8, Id)>> = vec![None; raw.len()];
    let mut objects: HashMap<Id, (u8, Vec<u8>)> = HashMap::new();
    let mut left = raw.len();
    while left > 0 {
        let before = left;
        for i in 0..raw.len() {
            if done[i].is_some() {
                continue;
            }
            let base = match &raw[i].3 {
                None => None,
                Some(Base::Ofs(o)) => Some(at.get(o).and_then(|&j| done[j]).map(|(_, id)| id)),
                Some(Base::Ref(id)) => Some(objects.contains_key(id).then_some(*id)),
            };
            let resolved = match base {
                None => Some((raw[i].1, std::mem::take(&mut raw[i].2))),
                Some(id) => match id.and_then(|id| objects.get(&id)) {
                    Some((kind, data)) => Some((*kind, apply_delta(data, &raw[i].2)?)),
                    None => None,
                },
            };
            if let Some((kind, data)) = resolved {
                total = total.saturating_add(data.len() as u64);
                if total > max.saturating_mul(2) {
                    bail!(IO, "git: repository content exceeds {max} bytes");
                }
                let id = object_id(kind, &data);
                objects.insert(id, (kind, data));
                done[i] = Some((kind, id));
                left -= 1;
            }
        }
        if left == before {
            return Err(bad("delta without its base"));
        }
    }
    Ok(objects)
}

fn hex_id(s: &str) -> Option<Id> {
    hex::decode(s).ok()?.try_into().ok()
}

struct Commit {
    tree: Id,
    parent: Option<Id>,
    time: Timestamp,
}

fn parse_commit(data: &[u8]) -> Option<Commit> {
    let text = String::from_utf8_lossy(data);
    let (mut tree, mut parent, mut time) = (None, None, None);
    for line in text.lines().take_while(|l| !l.is_empty()) {
        match line.split_once(' ') {
            Some(("tree", t)) => tree = hex_id(t),
            Some(("parent", p)) if parent.is_none() => parent = hex_id(p),
            Some(("committer", c)) => {
                let mut words = c.rsplit(' ');
                let _zone = words.next();
                time = words.next().and_then(|s| s.parse::<i64>().ok()).and_then(|s| Timestamp::from_second(s).ok());
            }
            _ => {}
        }
    }
    Some(Commit { tree: tree?, parent, time: time? })
}

/// Commit `sha` with its committer date. Fetched without trees where the server allows filters.
fn commit_info(http: &Http, r: &Remote, url: &str, sha: &str) -> Result<(Timestamp, Option<String>)> {
    static SEEN: Mutex<Vec<(String, Timestamp, Option<String>)>> = Mutex::new(Vec::new());
    let key = format!("{url}@{sha}");
    if let Some((_, t, p)) = SEEN.lock().unwrap_or_else(|e| e.into_inner()).iter().find(|(k, ..)| *k == key) {
        return Ok((*t, p.clone()));
    }
    let limits = Limits::default();
    let filter = r.has("filter");
    let objects = parse_pack(&fetch_pack(http, r, url, sha, 1, filter, limits.download)?, limits.unpacked)?;
    let c = commit_of(&objects, url, sha)?;
    let parent = c.parent.map(hex::encode);
    SEEN.lock().unwrap_or_else(|e| e.into_inner()).push((key, c.time, parent.clone()));
    Ok((c.time, parent))
}

fn commit_of(objects: &HashMap<Id, (u8, Vec<u8>)>, url: &str, sha: &str) -> Result<Commit> {
    let id = hex_id(sha).ok_or_else(|| Error::new(MANIFEST, format!("git: {sha:?} is not a commit sha")))?;
    match objects.get(&id) {
        Some((1, data)) => parse_commit(data).ok_or_else(|| Error::new(NETWORK, format!("git: {url}: malformed commit {sha}"))),
        _ => bail!(NETWORK, "git: {url}: the server did not send commit {sha}"),
    }
}

/// The newest commit on `sha`'s first-parent line committed at or before `cutoff`, reading up
/// to `HISTORY` commits without their trees. `None`: none of them, or the server cannot filter.
fn older_commit(http: &Http, r: &Remote, url: &str, sha: &str, cutoff: Timestamp) -> Result<Option<(String, Timestamp)>> {
    if !r.has("filter") || !r.has("shallow") {
        return Ok(None);
    }
    let limits = Limits::default();
    let objects = parse_pack(&fetch_pack(http, r, url, sha, HISTORY, true, limits.download)?, limits.unpacked)?;
    let mut at = hex_id(sha);
    for _ in 0..HISTORY {
        let Some((1, data)) = at.and_then(|id| objects.get(&id)) else { break };
        let Some(c) = parse_commit(data) else { break };
        if c.time <= cutoff {
            return Ok(Some((hex::encode(at.expect("set")), c.time)));
        }
        at = c.parent;
    }
    Ok(None)
}

/// A commit's files as a zip under one top directory, like a GitHub zipball, and the sha256 the
/// lock records for it: over the sorted lines `<path>\0<mode>\0<sha256 of content>\n` (mode
/// `644`, `755` or `120000` with the link target as content), so it does not depend on how the
/// zip is written.
pub struct Checkout {
    pub zip: Vec<u8>,
    pub sha256: String,
}

pub fn checkout(http: &Http, url: &str, sha: &str, limits: &Limits) -> Result<Checkout> {
    if !is_sha(sha) {
        bail!(MANIFEST, "git: {url}: locked reference {sha:?} is not a commit sha");
    }
    let r = remote(http, url)?;
    let objects = parse_pack(&fetch_pack(http, &r, url, sha, 1, false, limits.download)?, limits.unpacked)?;
    let commit = commit_of(&objects, url, sha)?;
    let mut files: Vec<(String, u32, Vec<u8>)> = Vec::new();
    walk(&objects, url, commit.tree, "", 0, &mut files, limits)?;
    files.sort_by(|a, b| a.0.cmp(&b.0));
    let top = format!("{}-{}", name_of(url).map_or("repo".into(), |n| n.replace('/', "-")), &sha[..12]);
    let mut w = ZipWriter::new(std::io::Cursor::new(Vec::new()));
    let mut listing = Vec::new();
    for (path, mode, data) in &files {
        let opts = SimpleFileOptions::DEFAULT.compression_method(CompressionMethod::Stored).system(System::Unix);
        let full = format!("{top}/{path}");
        if *mode == 0o120000 {
            w.add_symlink(full, String::from_utf8_lossy(data), opts)?;
        } else {
            w.start_file(full, opts.unix_permissions(*mode))?;
            w.write_all(data)?;
        }
        let shown = if *mode == 0o120000 { "120000".to_string() } else { format!("{mode:o}") };
        listing.extend(format!("{path}\0{shown}\0{}\n", hex::encode(Sha256::digest(data))).as_bytes());
    }
    Ok(Checkout { zip: w.finish()?.into_inner(), sha256: hex::encode(Sha256::digest(&listing)) })
}

fn walk(
    objects: &HashMap<Id, (u8, Vec<u8>)>,
    url: &str,
    tree: Id,
    prefix: &str,
    depth: usize,
    out: &mut Vec<(String, u32, Vec<u8>)>,
    limits: &Limits,
) -> Result<()> {
    let missing = |what: &str| Error::new(NETWORK, format!("git: {url}: the server did not send {what}"));
    if depth > 64 {
        bail!(IO, "git: {url}: directories nested deeper than 64");
    }
    let Some((2, data)) = objects.get(&tree) else { return Err(missing("a tree")) };
    let mut pos = 0;
    while pos < data.len() {
        let space = data[pos..].iter().position(|&c| c == b' ').ok_or_else(|| missing("a valid tree"))? + pos;
        let nul = data[space..].iter().position(|&c| c == 0).ok_or_else(|| missing("a valid tree"))? + space;
        let mode = std::str::from_utf8(&data[pos..space]).ok().and_then(|m| u32::from_str_radix(m, 8).ok());
        let name = String::from_utf8_lossy(&data[space + 1..nul]).into_owned();
        let id: Id = data.get(nul + 1..nul + 21).ok_or_else(|| missing("a valid tree"))?.try_into().expect("20 bytes");
        pos = nul + 21;
        if name.is_empty() || name == "." || name == ".." || name.contains('/') {
            bail!(IO, "git: {url}: unsafe path {name:?}");
        }
        let path = if prefix.is_empty() { name } else { format!("{prefix}/{name}") };
        match mode {
            Some(0o40000) => walk(objects, url, id, &path, depth + 1, out, limits)?,
            // Submodules point into other repositories, which are not fetched.
            Some(0o160000) => {}
            Some(m @ (0o100644 | 0o100755 | 0o100664 | 0o120000)) => {
                let Some((3, blob)) = objects.get(&id) else { return Err(missing(&path)) };
                if out.len() >= limits.files {
                    bail!(IO, "git: {url}: more than {} files", limits.files);
                }
                let mode = match m {
                    0o100755 => 0o755,
                    0o120000 => 0o120000,
                    _ => 0o644,
                };
                out.push((path, mode, blob.clone()));
            }
            _ => bail!(IO, "git: {url}: {path:?} has an unsupported mode"),
        }
    }
    Ok(())
}

fn candidate(req: &SkillReq, url: &str, version: String, parsed: Version, sha: &str, time: Option<Timestamp>) -> Candidate {
    Candidate {
        name: req.name.clone(),
        version,
        parsed,
        time,
        dist: Dist { kind: KIND.into(), url: url.to_string(), reference: Some(sha.to_string()) },
        dist_shasum: None,
        skill_paths: Vec::new(),
        abandoned: None,
        description: None,
        license: Vec::new(),
    }
}

/// Tags that parse as versions, newest first, without times.
pub fn tags(http: &Http, req: &SkillReq, url: &str) -> Result<Vec<Candidate>> {
    let r = remote(http, url)?;
    let mut out: Vec<Candidate> = Vec::new();
    let mut names: Vec<(&String, &String)> = r.refs.iter().filter(|(n, _)| n.starts_with("refs/tags/")).collect();
    names.sort();
    for (name, sha) in names {
        let tag = &name["refs/tags/".len()..];
        if let Some(parsed) = Version::parse(tag).filter(|v| !out.iter().any(|c| &c.parsed == v)) {
            out.push(candidate(req, url, tag.to_string(), parsed, sha, None));
        }
    }
    out.sort_by(|a, b| b.parsed.cmp(&a.parsed));
    Ok(out)
}

fn sha_of(r: &Remote, url: &str, git_ref: &str) -> Result<String> {
    if is_sha(git_ref) {
        return Ok(git_ref.to_ascii_lowercase());
    }
    let names = if git_ref == DEFAULT_REF {
        vec![DEFAULT_REF.to_string()]
    } else {
        vec![format!("refs/heads/{git_ref}"), format!("refs/tags/{git_ref}"), git_ref.to_string()]
    };
    names
        .iter()
        .find_map(|n| r.refs.get(n).cloned())
        .ok_or_else(|| Error::new(MANIFEST, format!("git: {url}: no branch or tag {git_ref:?}")))
}

/// As `github::resolve`, with commit dates as the only times: git servers keep no push or
/// release times (D30).
pub fn resolve(http: &Http, req: &SkillReq, url: &str, min_age: SignedDuration, now: Timestamp) -> Result<Candidate> {
    let name = &req.name;
    let cutoff = now.checked_sub(min_age).unwrap_or(Timestamp::MIN);
    let r = remote(http, url)?;
    match req.github {
        Some(GitHub::Tags) => {
            let mut cands = tags(http, req, url)?;
            if cands.is_empty() {
                bail!(MANIFEST, "{name}: the repository has no version tags; use `ref` instead of `version`");
            }
            let c = Constraint::parse(&req.constraint).map_err(|e| Error::new(MANIFEST, format!("{name}: {e}")))?;
            for x in cands.iter_mut().filter(|x| c.allows(&x.parsed)) {
                let t = commit_info(http, &r, url, x.dist.reference.as_deref().expect("set by candidate"))?.0;
                x.time = Some(t);
                if t <= cutoff {
                    break;
                }
            }
            registry::select(&cands, name, &req.constraint, min_age, now)
        }
        Some(GitHub::Ref) => {
            let git_ref = &req.constraint;
            let mut sha = sha_of(&r, url, git_ref)?;
            let mut time = commit_info(http, &r, url, &sha)?.0;
            if time > cutoff {
                let eligible = time.checked_add(min_age).unwrap_or(Timestamp::MAX).round(jiff::Unit::Second).unwrap_or(time);
                if is_sha(git_ref) {
                    bail!(
                        MANIFEST,
                        "{name}: commit {git_ref} is newer than policy.min-release-age ({min_age}); it becomes eligible at {eligible}",
                        min_age = crate::manifest::Age(min_age)
                    );
                }
                let Some((older, t)) = older_commit(http, &r, url, &sha, cutoff)? else {
                    bail!(
                        MANIFEST,
                        "{name}: the newest commit on {git_ref:?} is newer than policy.min-release-age ({min_age}) and no older one was found; it becomes eligible at {eligible}",
                        min_age = crate::manifest::Age(min_age)
                    );
                };
                crate::ui::note(format!("{name}: newer commits on {git_ref:?} are within policy.min-release-age; using {}", &older[..12]));
                (sha, time) = (older, t);
            }
            let parsed = Version::parse("0.0.0").expect("valid");
            Ok(candidate(req, url, sha[..12].to_string(), parsed, &sha, Some(time)))
        }
        None => unreachable!("only git entries are resolved here"),
    }
}

/// (newest within the constraint, newest overall) for `outdated`; cooldown is not applied.
pub fn newest(http: &Http, req: &SkillReq, url: &str) -> Result<(Option<String>, Option<String>)> {
    if req.github == Some(GitHub::Ref) {
        let head = sha_of(&remote(http, url)?, url, &req.constraint)?[..12].to_string();
        return Ok((Some(head.clone()), Some(head)));
    }
    let cands = tags(http, req, url)?;
    let c = Constraint::parse(&req.constraint).map_err(|e| Error::new(MANIFEST, format!("{}: {e}", req.name)))?;
    let v = |x: Option<&Candidate>| x.map(|x| x.version.clone());
    Ok((v(registry::newest(&cands, Some(&c))), v(registry::newest(&cands, None))))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urls_and_names() {
        assert_eq!(name_of("https://git.example.com/Acme/Skills.git").as_deref(), Some("acme/skills"));
        assert_eq!(name_of("https://dev.azure.com/org/project/_git/skills").as_deref(), Some("project/skills"));
        assert!(check_url("https://git.example.com/acme/skills.git").is_ok());
        for bad in [
            "http://git.example.com/a/b",
            "https://u:p@git.example.com/a/b",
            "https://git.example.com/a/b?x=1",
            "https://git.example.com/b",
        ] {
            assert!(check_url(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn deltas_copy_and_insert() {
        let base = b"hello world";
        // base size 11, result size 11: copy "hello " (offset 0, len 6), insert "there".
        let delta = [11, 11, 0x80 | 0x01 | 0x10, 0, 6, 5, b't', b'h', b'e', b'r', b'e'];
        assert_eq!(apply_delta(base, &delta).unwrap(), b"hello there");
        assert!(apply_delta(b"short", &delta).is_err());
    }

    #[test]
    fn reads_the_ref_advertisement() {
        let mut b = Vec::new();
        pkt_line(&mut b, "# service=git-upload-pack\n");
        b.extend(b"0000");
        let (a, t, c) = ("a".repeat(40), "b".repeat(40), "c".repeat(40));
        pkt_line(&mut b, &format!("{a} HEAD\0shallow side-band-64k symref=HEAD:refs/heads/main\n"));
        pkt_line(&mut b, &format!("{a} refs/heads/main\n"));
        pkt_line(&mut b, &format!("{t} refs/tags/v1.0.0\n"));
        pkt_line(&mut b, &format!("{c} refs/tags/v1.0.0^{{}}\n"));
        b.extend(b"0000");
        let r = parse_refs(&b).unwrap();
        assert_eq!(r.refs["HEAD"], a);
        assert_eq!(r.refs["refs/tags/v1.0.0"], c, "annotated tags resolve to their commit");
        assert!(r.has("shallow") && r.has("symref") && !r.has("filter"));
        assert!(parse_refs(b"001e# service=git-receive-pack\n0000").is_err());
    }
}
