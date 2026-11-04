//! Composer repository client (v2 `metadata-url`, or v1 inline `packages`): metadata, skill
//! filtering, version selection.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use jiff::{SignedDuration, Timestamp};
use serde_json::{Map, Value};
use url::Url;

use crate::bail;
use crate::error::{Error, MANIFEST, NETWORK, Result};
use crate::http::Http;
use crate::lock::Dist;
use crate::manifest::Repository;
use crate::version::{Constraint, Stability, Version};

/// One `search` result. `skills`: how many skills the package lists; `requires`: what its
/// `publish` recorded from `requires:` (D49). Packagist's search gives neither.
pub struct Hit {
    pub name: String,
    pub description: String,
    pub source: String,
    pub skills: Option<usize>,
    pub requires: std::collections::BTreeMap<String, String>,
}

#[derive(Clone, Debug)]
pub struct Candidate {
    pub name: String,
    pub version: String,
    pub parsed: Version,
    pub time: Option<Timestamp>,
    pub dist: Dist,
    pub dist_shasum: Option<String>,
    pub skill_paths: Vec<String>,
    /// Composer `abandoned`: `Some(replacement)` when set.
    pub abandoned: Option<Option<String>>,
    pub description: Option<String>,
    pub license: Vec<String>,
}

/// A published security advisory (D55). `affected`: Composer constraints, any of which matches an
/// affected version; empty, or a `None` among them, means every version.
pub struct Advisory {
    pub package: String,
    pub id: Option<String>,
    pub cve: Option<String>,
    pub title: Option<String>,
    pub severity: Option<String>,
    pub link: Option<String>,
    pub published: Option<Timestamp>,
    pub affected: Vec<Option<String>>,
}

impl Advisory {
    /// Whether the locked `version` is affected. `pinned`: the entry is locked at a commit, with
    /// the time it was released; a commit has no version to match, so only an advisory published
    /// after it counts (one published before is taken as fixed by then). A version or range
    /// skillcask cannot read counts as affected, so no advisory is dropped for its format.
    pub fn affects(&self, version: &str, pinned: Option<Option<Timestamp>>) -> bool {
        if let Some(released) = pinned {
            return self.published.zip(released).is_none_or(|(p, r)| p > r);
        }
        let Some(v) = Version::parse(version) else { return true };
        self.affected.is_empty()
            || self.affected.iter().any(|r| r.as_deref().is_none_or(|r| Constraint::parse(r).ok().is_none_or(|c| c.matches(&v))))
    }

    pub fn describe(&self) -> String {
        let mut tags: Vec<String> = self.id.iter().cloned().collect();
        tags.extend(self.cve.clone().filter(|c| self.id.as_ref() != Some(c)));
        tags.extend(self.severity.clone());
        let mut s = if tags.is_empty() { "advisory".to_string() } else { format!("advisory {}", tags.join(", ")) };
        if let Some(t) = &self.title {
            s.push_str(&format!(": {t}"));
        }
        if let Some(l) = &self.link {
            s.push_str(&format!(" ({l})"));
        }
        crate::skill::shown(&s)
    }
}

/// Names per advisories request: Packagist answers 414 above about 8 KB of query.
const ADVISORY_BATCH: usize = 50;

const SEARCH_LIMIT: usize = 30;

type Versions = Vec<Map<String, Value>>;

pub struct Registry<'a> {
    http: &'a Http,
    roots: RefCell<HashMap<String, Rc<(Url, Value)>>>,
}

fn packages_url(repo: &Repository) -> Result<Url> {
    // A query string means an API endpoint (e.g. GitLab raw files `.../raw?ref=main`), used as given.
    let raw = if repo.url.ends_with(".json") || repo.url.contains('?') {
        repo.url.clone()
    } else {
        format!("{}/packages.json", repo.url.trim_end_matches('/'))
    };
    Url::parse(&raw).map_err(|e| Error::new(MANIFEST, format!("repository {}: invalid url: {e}", repo.name)))
}

fn is_packagist(repo: &Repository) -> bool {
    Url::parse(&repo.url).ok().and_then(|u| u.host_str().map(|h| h == "packagist.org" || h.ends_with(".packagist.org"))).unwrap_or(false)
}

/// `None` when the root lists its packages and `package` is not among them.
fn metadata_url(root: &Value, base: &Url, package: &str) -> Result<Option<Url>> {
    let names = root.get("available-packages").and_then(Value::as_array);
    let patterns = root.get("available-package-patterns").and_then(Value::as_array);
    if names.is_some() || patterns.is_some() {
        let listed = names.into_iter().flatten().any(|n| n.as_str() == Some(package))
            || patterns.into_iter().flatten().filter_map(Value::as_str).any(|p| glob(p, package));
        if !listed {
            return Ok(None);
        }
    }
    let Some(tpl) = root.get("metadata-url").and_then(Value::as_str) else {
        if root.get("packages").is_some_and(Value::is_object) {
            return Ok(None);
        }
        bail!(MANIFEST, "{}: no metadata-url and no inline packages", crate::http::redact(base));
    };
    base.join(&tpl.replace("%package%", package)).map(Some).map_err(|e| Error::new(NETWORK, format!("bad metadata-url {tpl:?}: {e}")))
}

/// Composer v1 inline metadata: `packages.<name>` maps version to metadata (Satis); a list is
/// accepted too.
fn inline(root: &Value, package: &str) -> Option<Vec<Value>> {
    match root.get("packages")?.get(package)? {
        Value::Object(m) => Some(m.values().cloned().collect()),
        Value::Array(a) => Some(a.clone()),
        _ => None,
    }
}

fn glob(pattern: &str, s: &str) -> bool {
    let mut parts = pattern.split('*');
    let first = parts.next().unwrap_or("");
    let Some(mut rest) = s.strip_prefix(first) else { return false };
    let parts: Vec<&str> = parts.collect();
    for (i, p) in parts.iter().enumerate() {
        if i == parts.len() - 1 {
            return rest.ends_with(p);
        }
        match rest.find(p) {
            Some(at) => rest = &rest[at + p.len()..],
            None => return false,
        }
    }
    rest.is_empty()
}

/// Expands Composer's minified format: each version inherits fields from the previous one.
fn expand(versions: &[Value], minified: bool) -> Vec<Map<String, Value>> {
    let mut acc = Map::new();
    let mut out = Vec::new();
    for v in versions {
        let Some(obj) = v.as_object() else { continue };
        if !minified {
            out.push(obj.clone());
            continue;
        }
        for (k, val) in obj {
            if val.as_str() == Some("__unset") {
                acc.remove(k);
            } else {
                acc.insert(k.clone(), val.clone());
            }
        }
        out.push(acc.clone());
    }
    out
}

/// Composer writes `time` with or without an offset; without one it is UTC.
fn release_time(t: &str) -> Option<Timestamp> {
    t.parse().ok().or_else(|| t.parse::<jiff::civil::DateTime>().ok()?.to_zoned(jiff::tz::TimeZone::UTC).ok().map(|z| z.timestamp()))
}

fn candidates(package: &str, versions: Vec<Map<String, Value>>, base: &Url) -> Vec<Candidate> {
    let s = |m: &Map<String, Value>, path: &[&str]| -> Option<String> {
        let mut v = m.get(path[0])?;
        for k in &path[1..] {
            v = v.get(k)?;
        }
        v.as_str().filter(|s| !s.is_empty()).map(String::from)
    };
    let mut out = Vec::new();
    for m in versions {
        let extra = m.get("extra").and_then(|e| e.get("ai-agent-skill"));
        if s(&m, &["type"]).as_deref() != Some("ai-agent-skill") && extra.is_none() {
            continue;
        }
        let Some(version) = s(&m, &["version"]) else { continue };
        let Some(parsed) = s(&m, &["version_normalized"]).and_then(|n| Version::parse(&n)).or_else(|| Version::parse(&version)) else {
            continue;
        };
        // Userinfo of the repository URL must not end up in the lock.
        let dist_url = s(&m, &["dist", "url"]).and_then(|u| base.join(&u).ok()).map(|mut u| {
            let _ = u.set_username("");
            let _ = u.set_password(None);
            u
        });
        let (Some("zip"), Some(url)) = (s(&m, &["dist", "type"]).as_deref(), dist_url) else {
            crate::ui::warn(format!("skipping {package} {version}: no zip dist"));
            continue;
        };
        let skill_paths = match extra {
            Some(Value::String(p)) => vec![p.clone()],
            Some(Value::Array(a)) => a.iter().filter_map(Value::as_str).map(String::from).collect(),
            _ => vec![crate::skill::SKILL_MD.to_string()],
        };
        let time = s(&m, &["time"]).and_then(|t| {
            let parsed = release_time(&t);
            if parsed.is_none() {
                crate::ui::warn(format!("{package} {version}: unrecognised release time {t:?}"));
            }
            parsed
        });
        out.push(Candidate {
            name: package.to_string(),
            parsed,
            time,
            dist: Dist {
                kind: "zip".into(),
                url: url.to_string(),
                reference: s(&m, &["dist", "reference"]).or_else(|| s(&m, &["source", "reference"])),
            },
            dist_shasum: s(&m, &["dist", "shasum"]),
            skill_paths,
            version,
            abandoned: match m.get("abandoned") {
                Some(Value::Bool(true)) => Some(None),
                Some(Value::String(r)) => Some(Some(r.clone()).filter(|r| !r.is_empty())),
                _ => None,
            },
            description: s(&m, &["description"]),
            license: match m.get("license") {
                Some(Value::String(l)) => vec![l.clone()],
                Some(Value::Array(a)) => a.iter().filter_map(Value::as_str).map(String::from).collect(),
                _ => Vec::new(),
            },
        });
    }
    out.sort_by(|a, b| b.parsed.cmp(&a.parsed));
    out
}

impl<'a> Registry<'a> {
    pub fn new(http: &'a Http) -> Self {
        Registry { http, roots: RefCell::new(HashMap::new()) }
    }

    fn root(&self, repo: &Repository) -> Result<Rc<(Url, Value)>> {
        if let Some(r) = self.roots.borrow().get(&repo.url) {
            return Ok(r.clone());
        }
        let url = packages_url(repo)?;
        let json = self.http.get_json(url.as_str())?.ok_or_else(|| {
            // GitLab answers 404, not 401, for a private project read without a token.
            let hint = match crate::http::auth_key(&url) {
                Some(host) if !self.http.has_credential(url.as_str()) => format!(" (private repository? `skillcask auth set {host}`)"),
                _ => String::new(),
            };
            Error::new(NETWORK, format!("repository {}: {} not found{hint}", repo.name, crate::http::redact(&url)))
        })?;
        let r = Rc::new((url, json));
        self.roots.borrow_mut().insert(repo.url.clone(), r.clone());
        Ok(r)
    }

    /// Advisories for `packages` from the API the repository's `packages.json` names in
    /// `security-advisories.api-url` (Packagist does); `None` when it names none (D55).
    pub fn advisories(&self, repo: &Repository, packages: &[&str]) -> Result<Option<Vec<Advisory>>> {
        let root = self.root(repo)?;
        let Some(api) = root.1.get("security-advisories").and_then(|a| a.get("api-url")).and_then(Value::as_str) else {
            return Ok(None);
        };
        let base = root.0.join(api).map_err(|e| Error::new(NETWORK, format!("bad security-advisories api-url {api:?}: {e}")))?;
        let s = |a: &Value, k: &str| a.get(k).and_then(Value::as_str).filter(|s| !s.is_empty()).map(String::from);
        let mut out = Vec::new();
        for batch in packages.chunks(ADVISORY_BATCH) {
            let mut url = base.clone();
            for p in batch {
                url.query_pairs_mut().append_pair("packages[]", p);
            }
            let json =
                self.http.get_json(url.as_str())?.ok_or_else(|| Error::new(NETWORK, format!("{} not found", crate::http::redact(&url))))?;
            for p in batch {
                for a in json.get("advisories").and_then(|m| m.get(*p)).and_then(Value::as_array).into_iter().flatten() {
                    out.push(Advisory {
                        package: p.to_string(),
                        id: s(a, "advisoryId"),
                        cve: s(a, "cve"),
                        title: s(a, "title"),
                        severity: s(a, "severity"),
                        link: s(a, "link"),
                        published: s(a, "reportedAt").and_then(|t| release_time(&t)),
                        affected: vec![s(a, "affectedVersions")],
                    });
                }
            }
        }
        Ok(Some(out))
    }

    pub fn versions(&self, repo: &Repository, package: &str) -> Result<Option<Vec<Candidate>>> {
        Ok(self.metadata(repo, package)?.map(|(list, base)| candidates(package, list, &base)))
    }

    /// Every version's metadata, expanded, and the URL relative dist URLs resolve against.
    fn metadata(&self, repo: &Repository, package: &str) -> Result<Option<(Versions, Url)>> {
        let root = self.root(repo)?;
        if let Some(list) = inline(&root.1, package) {
            return Ok(Some((expand(&list, false), root.0.clone())));
        }
        let Some(meta) = metadata_url(&root.1, &root.0, package)? else { return Ok(None) };
        let Some(p2) = self.http.get_json(meta.as_str())? else { return Ok(None) };
        let Some(list) = p2.get("packages").and_then(|p| p.get(package)).and_then(Value::as_array) else { return Ok(None) };
        let minified = p2.get("minified").and_then(Value::as_str) == Some("composer/2.0");
        Ok(Some((expand(list, minified), meta)))
    }

    pub fn find(&self, repos: &[Repository], package: &str, only: Option<&str>) -> Result<(Repository, Vec<Candidate>)> {
        let searched: Vec<&Repository> = match only {
            Some(n) => vec![repos.iter().find(|r| r.name == n).ok_or_else(|| Error::new(MANIFEST, format!("unknown repository {n:?}")))?],
            None => repos.iter().collect(),
        };
        for repo in &searched {
            if let Some(c) = self.versions(repo, package)? {
                if c.is_empty() {
                    bail!(MANIFEST, "{package} in repository {} has no installable ai-agent-skill versions", repo.name);
                }
                return Ok(((*repo).clone(), c));
            }
        }
        let names: Vec<&str> = searched.iter().map(|r| r.name.as_str()).collect();
        bail!(MANIFEST, "package {package} not found in repositories {}", names.join(", "))
    }

    /// (name, description, repository name) of skill packages whose name contains `query`, or that
    /// Packagist's search finds. A repository that fails is skipped with a warning; all failing is an error.
    pub fn search(&self, repos: &[Repository], query: &str) -> Result<Vec<Hit>> {
        let mut out = Vec::new();
        let (mut failed, mut errors) = (None, 0);
        for repo in repos {
            let found = if is_packagist(repo) { self.search_packagist(query) } else { self.search_names(repo, query) };
            match found {
                Ok(f) => out.extend(f.into_iter().map(|h| Hit { source: repo.name.clone(), ..h })),
                Err(e) => {
                    let prefix = format!("repository {}: ", repo.name);
                    crate::ui::warn(if e.msg.starts_with(&prefix) { e.msg.clone() } else { format!("{prefix}{}", e.msg) });
                    (failed, errors) = (Some(e), errors + 1);
                }
            }
        }
        if let Some(e) = failed.filter(|_| errors == repos.len()) {
            return Err(e);
        }
        let mut seen = std::collections::HashSet::new();
        out.retain(|h| seen.insert(h.name.clone()));
        Ok(out)
    }

    fn search_packagist(&self, query: &str) -> Result<Vec<Hit>> {
        let mut out = Vec::new();
        let mut url = Url::parse_with_params("https://packagist.org/search.json", [("q", query), ("type", "ai-agent-skill")])
            .map_err(|e| Error::new(NETWORK, e.to_string()))?
            .to_string();
        for _ in 0..3 {
            let Some(page) = self.http.get_json(&url)? else { break };
            for r in page.get("results").and_then(Value::as_array).into_iter().flatten() {
                if let Some(n) = r.get("name").and_then(Value::as_str) {
                    out.push(Hit {
                        name: n.to_string(),
                        description: r.get("description").and_then(Value::as_str).unwrap_or("").to_string(),
                        source: String::new(),
                        skills: None,
                        requires: Default::default(),
                    });
                }
            }
            match page.get("next").and_then(Value::as_str) {
                Some(n) => url = n.to_string(),
                None => break,
            }
        }
        Ok(out)
    }

    /// Names come from `available-packages`, inline `packages` or, on GitLab, `provider-includes`;
    /// each match's metadata is read to keep skill packages only.
    fn search_names(&self, repo: &Repository, query: &str) -> Result<Vec<Hit>> {
        let root = self.root(repo)?;
        let q = query.to_lowercase();
        let mut names: Vec<String> = root
            .1
            .get("available-packages")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(String::from)
            .collect();
        names.extend(root.1.get("packages").and_then(Value::as_object).into_iter().flat_map(|m| m.keys().cloned()));
        for (tpl, h) in root.1.get("provider-includes").and_then(Value::as_object).into_iter().flatten() {
            let Some(hash) = h.get("sha256").and_then(Value::as_str) else { continue };
            let url = root
                .0
                .join(&tpl.replace("%hash%", hash))
                .map_err(|e| Error::new(NETWORK, format!("bad provider-includes {tpl:?}: {e}")))?;
            let providers = self.http.get_json(url.as_str())?;
            names.extend(providers.as_ref().and_then(|p| p.get("providers")?.as_object()).into_iter().flat_map(|m| m.keys().cloned()));
        }
        names.sort();
        names.dedup();
        names.retain(|n| n.contains(&q));
        // A match after the vendor first: a query that is the vendor matches every package.
        names.sort_by_key(|n| !n.split_once('/').map_or(n.as_str(), |(_, short)| short).contains(&q));
        // ponytail: one metadata request per match not inline, capped; a server-side search would lift the cap.
        let fetched = names.iter().filter(|n| inline(&root.1, n).is_none()).count();
        if fetched > SEARCH_LIMIT {
            crate::ui::warn(format!(
                "repository {}: {fetched} packages match; only the first {SEARCH_LIMIT} are checked; narrow the query",
                repo.name
            ));
            let mut left = SEARCH_LIMIT;
            names.retain(|n| {
                let keep = inline(&root.1, n).is_some() || left > 0;
                if inline(&root.1, n).is_none() {
                    left = left.saturating_sub(1);
                }
                keep
            });
        }
        let mut out = Vec::new();
        for n in names {
            let Some((list, _)) = self.metadata(repo, &n)? else { continue };
            let newest = list
                .iter()
                .filter(|m| {
                    m.get("type").and_then(Value::as_str) == Some("ai-agent-skill")
                        || m.get("extra").and_then(|e| e.get("ai-agent-skill")).is_some()
                })
                .max_by_key(|m| {
                    ["version_normalized", "version"].iter().find_map(|k| m.get(*k).and_then(Value::as_str).and_then(Version::parse))
                });
            if let Some(m) = newest {
                let extra = m.get("extra");
                out.push(Hit {
                    name: n,
                    description: m.get("description").and_then(Value::as_str).unwrap_or("").to_string(),
                    source: String::new(),
                    skills: Some(extra.and_then(|e| e.get("ai-agent-skill")?.as_array().map(Vec::len)).unwrap_or(1)),
                    requires: extra
                        .and_then(|e| e.get(crate::publish::REQUIRES)?.as_object())
                        .into_iter()
                        .flatten()
                        .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_string())))
                        .collect(),
                });
            }
        }
        Ok(out)
    }
}

/// `SKILLCASK_SKILLS_SH` points at a test server.
fn skills_sh_base() -> String {
    std::env::var("SKILLCASK_SKILLS_SH").ok().filter(|v| !v.is_empty()).unwrap_or_else(|| "https://skills.sh".into())
}

/// `github:owner/repo/skill` and install count of what skills.sh's search (the API `npx skills
/// find` calls, undocumented) finds for `query` (D42).
pub fn search_skills_sh(http: &Http, query: &str) -> Result<Vec<(String, Option<u64>)>> {
    let url = Url::parse_with_params(&format!("{}/api/search", skills_sh_base().trim_end_matches('/')), [("q", query), ("limit", "20")])
        .map_err(|e| Error::new(NETWORK, e.to_string()))?;
    Ok(http.get_json(url.as_str())?.map_or_else(Vec::new, |v| skills_sh_results(&v)))
}

/// Entries whose `source` is not `owner/repo` or whose `skillId` is not a skill name are dropped.
fn skills_sh_results(v: &Value) -> Vec<(String, Option<u64>)> {
    let entry = |e: &Value| {
        let source = e.get("source")?.as_str()?.to_lowercase();
        let skill = e.get("skillId")?.as_str()?;
        (crate::manifest::valid_package_name(&source) && crate::skill::valid_name(skill))
            .then(|| (format!("github:{source}/{skill}"), e.get("installs").and_then(Value::as_u64)))
    };
    v.get("skills").and_then(Value::as_array).into_iter().flatten().filter_map(entry).collect()
}

pub fn select(cands: &[Candidate], name: &str, constraint: &str, min_age: SignedDuration, now: Timestamp) -> Result<Candidate> {
    let c = Constraint::parse(constraint).map_err(|e| Error::new(MANIFEST, format!("{name}: {e}")))?;
    let Some(newest) = newest(cands, Some(&c)) else {
        let latest = cands.iter().max_by(|a, b| a.parsed.cmp(&b.parsed)).map(|c| format!(" (newest: {})", c.version)).unwrap_or_default();
        bail!(MANIFEST, "no version of {name} matches {constraint:?}{latest}");
    };
    let cutoff = now.checked_sub(min_age).unwrap_or(Timestamp::MIN);
    // Equal versions (`v1.0.0` and `1.0.0`): prefer the timed, older one, so an untimed duplicate cannot skip the cooldown.
    let age = |x: &Candidate| x.time.unwrap_or(Timestamp::MAX);
    let pick = cands
        .iter()
        .filter(|x| c.allows(&x.parsed) && x.time.is_none_or(|t| t <= cutoff))
        .max_by(|a, b| a.parsed.cmp(&b.parsed).then_with(|| age(b).cmp(&age(a))));
    match pick {
        Some(p) => {
            if p.time.is_none() {
                crate::ui::warn(format!("{name} {} has no release time; cooldown not applied", p.version));
            }
            Ok(p.clone())
        }
        None => {
            let t = newest.time.expect("only timed versions are filtered out");
            let eligible = t.checked_add(min_age).unwrap_or(Timestamp::MAX);
            bail!(
                MANIFEST,
                "{name}: every version matching {constraint:?} is newer than policy.min-release-age ({min_age:#}); newest {} was released {} and becomes eligible at {}",
                newest.version,
                t.round(jiff::Unit::Second).unwrap_or(t),
                eligible.round(jiff::Unit::Second).unwrap_or(eligible)
            )
        }
    }
}

/// Composer marks the whole package, so the newest version's metadata decides. The replacement is
/// registry text: named only when it is a valid package name, and shown escaped.
pub fn abandoned(cands: &[Candidate]) -> Option<String> {
    let c = cands.first()?;
    let msg = match c.abandoned.as_ref()? {
        Some(r) if crate::manifest::valid_package_name(r) => format!("{} is abandoned; use {r} instead", c.name),
        _ => format!("{} is abandoned", c.name),
    };
    Some(crate::skill::shown(&msg))
}

pub fn warn_abandoned(cands: &[Candidate]) {
    if let Some(m) = abandoned(cands) {
        crate::ui::warn(m);
    }
}

pub fn newest<'c>(cands: &'c [Candidate], constraint: Option<&Constraint>) -> Option<&'c Candidate> {
    cands
        .iter()
        .filter(|x| match constraint {
            Some(c) => c.allows(&x.parsed),
            None => x.parsed.stability >= Stability::Stable,
        })
        .max_by(|a, b| a.parsed.cmp(&b.parsed))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn an_advisory_affects_what_its_ranges_match_and_what_it_cannot_read() {
        let a = |ranges: &[Option<&str>], published: Option<&str>| Advisory {
            package: "acme/x".into(),
            id: Some("PKSA-1".into()),
            cve: None,
            title: None,
            severity: None,
            link: None,
            published: published.map(|t| t.parse().unwrap()),
            affected: ranges.iter().map(|r| r.map(String::from)).collect(),
        };
        let at = |v: &str, adv: &Advisory| adv.affects(v, None);
        let composer = a(&[Some(">=1.0.0,<1.0.2|>=2.0.0,<2.1.0")], None);
        assert!(at("1.0.1", &composer) && at("v2.0.5", &composer));
        assert!(!at("1.0.2", &composer) && !at("3.0.0", &composer));
        let github = a(&[Some(">= 6, < 6.4.48"), Some("= 7.0.0")], None);
        assert!(at("6.4.47", &github) && at("7.0.0", &github) && !at("6.4.48", &github));
        // No range or an unreadable one: affected.
        assert!(at("1.0.0", &a(&[], None)) && at("1.0.0", &a(&[None], None)));
        assert!(at("1.0.0", &a(&[Some("not a range")], None)));
        // A commit pin is decided by time, not by whether its short sha parses as a version
        // (`123456789012` does, as 123456789012.0.0.0).
        let old = a(&[Some("<1.0.2")], Some("2026-01-01T00:00:00Z"));
        let commit = |released: &str| Some(Some(released.parse().unwrap()));
        assert!(!old.affects("123456789012", commit("2026-02-01T00:00:00Z")), "published before the commit");
        assert!(old.affects("abcdef123456", commit("2025-12-01T00:00:00Z")), "published after it");
        assert!(
            old.affects("123456789012", Some(None)) && a(&[Some("<1.0.2")], None).affects("123456789012", commit("2026-02-01T00:00:00Z"))
        );
    }

    fn p2() -> Value {
        json!({"minified": "composer/2.0", "packages": {"acme/x": [
            {"name": "acme/x", "description": "d", "version": "v2.0.0", "version_normalized": "2.0.0.0", "type": "ai-agent-skill",
             "time": "2026-10-19T11:00:00+00:00",
             "dist": {"type": "zip", "url": "/dist/x-2.0.0.zip", "reference": "r2", "shasum": ""},
             "extra": {"ai-agent-skill": ["skills/a/SKILL.md", "skills/b/SKILL.md"]}},
            {"version": "v1.1.0", "version_normalized": "1.1.0.0", "time": "2026-10-01T00:00:00+00:00",
             "dist": {"type": "zip", "url": "https://cdn.example.com/x-1.1.0.zip", "shasum": "abc"},
             "source": {"type": "git", "url": "https://g", "reference": "s11"}, "extra": "__unset"},
            {"version": "v1.0.0", "version_normalized": "1.0.0.0", "time": "__unset"},
            {"version": "dev-main", "version_normalized": "dev-main"},
            {"version": "v0.9.0", "version_normalized": "0.9.0.0", "type": "library"},
            {"version": "v0.8.0", "version_normalized": "0.8.0.0", "type": "ai-agent-skill", "dist": {"type": "tar", "url": "https://a/b.tar"}}
        ]}})
    }

    fn cands() -> Vec<Candidate> {
        let v = p2();
        let list = v["packages"]["acme/x"].as_array().unwrap();
        candidates("acme/x", expand(list, true), &Url::parse("https://repo.example.com/p2/acme/x.json").unwrap())
    }

    #[test]
    fn reads_skills_sh_defensively() {
        let v = serde_json::json!({ "skills": [
            { "source": "Owner/Repo", "skillId": "one", "installs": 5 },
            { "source": "o/r", "skillId": "two", "installs": "many" },
            { "source": "o/r/../x", "skillId": "bad" },
            { "source": "o/r", "skillId": "Bad\u{1b}" },
            { "source": "o/r" },
            7,
        ]});
        assert_eq!(skills_sh_results(&v), [("github:owner/repo/one".to_string(), Some(5)), ("github:o/r/two".to_string(), None)]);
        assert!(skills_sh_results(&serde_json::json!({ "skills": "x" })).is_empty());
        assert!(skills_sh_results(&serde_json::json!([])).is_empty());
    }

    #[test]
    fn expands_minified_and_filters() {
        let c = cands();
        assert_eq!(c.iter().map(|c| c.version.as_str()).collect::<Vec<_>>(), ["v2.0.0", "v1.1.0", "v1.0.0"]);
        assert_eq!(c[0].dist.url, "https://repo.example.com/dist/x-2.0.0.zip");
        assert_eq!(c[0].skill_paths, ["skills/a/SKILL.md", "skills/b/SKILL.md"]);
        assert_eq!(c[0].dist_shasum, None);
        assert_eq!(c[1].skill_paths, ["SKILL.md"], "__unset removes extra; type still inherited");
        assert_eq!(c[1].dist.reference.as_deref(), Some("s11"));
        assert_eq!(c[1].dist_shasum.as_deref(), Some("abc"));
        assert_eq!(c[2].time, None);
        let plain = expand(&[json!({"version": "1"}), json!({"x": 1})], false);
        assert!(plain[1].get("version").is_none());
    }

    #[test]
    fn reads_abandoned() {
        let base = Url::parse("https://repo.example.com/p2/acme/x.json").unwrap();
        let with = |a: Value| {
            let v = json!({"version": "1.0.0", "type": "ai-agent-skill", "dist": {"type": "zip", "url": "/x.zip"}, "abandoned": a});
            candidates("acme/x", vec![v.as_object().unwrap().clone()], &base).remove(0).abandoned
        };
        assert_eq!(with(json!(true)), Some(None));
        assert_eq!(with(json!("acme/y")), Some(Some("acme/y".into())));
        assert_eq!(with(json!("")), Some(None));
        assert_eq!(with(json!(false)), None);
        assert_eq!(cands()[0].abandoned, None);
    }

    #[test]
    fn selects_with_cooldown() {
        let c = cands();
        let now: Timestamp = "2026-10-19T12:00:00Z".parse().unwrap();
        let three_days = SignedDuration::from_hours(72);
        assert_eq!(select(&c, "acme/x", "^1.0", three_days, now).unwrap().version, "v1.1.0");
        assert_eq!(select(&c, "acme/x", "*", SignedDuration::ZERO, now).unwrap().version, "v2.0.0");
        assert_eq!(select(&c, "acme/x", "*", three_days, now).unwrap().version, "v1.1.0");
        let e = select(&c, "acme/x", "^2.0", three_days, now).unwrap_err();
        assert_eq!(e.code, MANIFEST);
        assert!(e.msg.contains("v2.0.0") && e.msg.contains("2026-10-22T11:00:00Z") && e.msg.contains("min-release-age"), "{}", e.msg);
        let e = select(&c, "acme/x", "^3.0", three_days, now).unwrap_err();
        assert!(e.msg.contains("no version of acme/x matches") && e.msg.contains("newest: v2.0.0"), "{}", e.msg);
        // 1.0.0 has no time: kept despite cooldown
        assert_eq!(select(&c, "acme/x", "1.0.0", SignedDuration::from_hours(100_000), now).unwrap().version, "v1.0.0");
        assert_eq!(newest(&c, None).unwrap().version, "v2.0.0");
        assert_eq!(newest(&c, Some(&Constraint::parse("~1.0").unwrap())).unwrap().version, "v1.1.0");
    }

    #[test]
    fn equal_versions_prefer_the_timed_one() {
        let now: Timestamp = "2026-10-19T12:00:00Z".parse().unwrap();
        let mut c = cands();
        c.truncate(2);
        let mut untimed = c[1].clone();
        untimed.version = "1.1.0".into();
        untimed.time = None;
        c.push(untimed);
        let picked = select(&c, "acme/x", "^1.0", SignedDuration::from_hours(72), now).unwrap();
        assert_eq!((picked.version.as_str(), picked.time.is_some()), ("v1.1.0", true));
    }

    #[test]
    fn times_without_offset_are_utc() {
        let v = |t: &str| json!({"version": "1.0.0", "type": "ai-agent-skill", "time": t, "dist": {"type": "zip", "url": "/x.zip"}});
        let base = Url::parse("https://repo.example.com/p2/acme/x.json").unwrap();
        let utc: Timestamp = "2026-10-19T11:00:00Z".parse().unwrap();
        for t in ["2026-10-19 11:00:00", "2026-10-19T11:00:00", "2026-10-19T11:00:00+00:00"] {
            let c = candidates("acme/x", expand(&[v(t)], false), &base);
            assert_eq!(c[0].time, Some(utc), "{t}");
            let now: Timestamp = "2026-10-19T12:00:00Z".parse().unwrap();
            assert!(select(&c, "acme/x", "*", SignedDuration::from_hours(72), now).is_err(), "cooldown applies to {t}");
        }
        assert_eq!(candidates("acme/x", expand(&[v("yesterday")], false), &base)[0].time, None);
    }

    #[test]
    fn userinfo_is_not_copied_into_dist_urls() {
        let v = json!({"version": "1.0.0", "type": "ai-agent-skill", "dist": {"type": "zip", "url": "/dist/x.zip"}});
        let base = Url::parse("https://u:secret@repo.example.com/p2/acme/x.json").unwrap();
        assert_eq!(candidates("acme/x", vec![v.as_object().unwrap().clone()], &base)[0].dist.url, "https://repo.example.com/dist/x.zip");
        let abs =
            json!({"version": "1.0.0", "type": "ai-agent-skill", "dist": {"type": "zip", "url": "https://u:p@cdn.example.com/x.zip"}});
        assert_eq!(candidates("acme/x", vec![abs.as_object().unwrap().clone()], &base)[0].dist.url, "https://cdn.example.com/x.zip");
    }

    #[test]
    fn huge_min_release_age_fails_closed() {
        use crate::manifest::parse_age;
        assert_eq!(parse_age("36525d").unwrap(), SignedDuration::from_hours(36525 * 24));
        assert!(parse_age("36526d").is_err(), "over 100 years");
        assert!(parse_age("9223372036854775807w").is_err(), "overflow");
        let c = cands();
        let now: Timestamp = "2026-10-19T12:00:00Z".parse().unwrap();
        let e = select(&c, "acme/x", "^1.1", SignedDuration::MAX, now).unwrap_err();
        assert!(e.msg.contains("min-release-age"), "{}", e.msg);
    }

    #[test]
    fn reads_inline_packages() {
        let v = json!({"version": "1.0.0", "type": "ai-agent-skill", "dist": {"type": "zip", "url": "https://h/x.zip"}});
        let root = json!({"packages": {"acme/x": {"1.0.0": v}, "acme/y": [v]}});
        assert_eq!(inline(&root, "acme/x").unwrap(), std::slice::from_ref(&v));
        assert_eq!(inline(&root, "acme/y").unwrap(), [v]);
        assert!(inline(&root, "acme/z").is_none());
        assert!(inline(&json!({"packages": []}), "acme/x").is_none());
    }

    #[test]
    fn resolves_metadata_url() {
        let base = Url::parse("https://git.example.com/api/v4/group/42/-/packages/composer/packages.json").unwrap();
        let root = json!({"metadata-url": "/api/v4/group/42/-/packages/composer/p2/%package%.json"});
        assert_eq!(
            metadata_url(&root, &base, "acme/x").unwrap().unwrap().as_str(),
            "https://git.example.com/api/v4/group/42/-/packages/composer/p2/acme/x.json"
        );
        let root =
            json!({"metadata-url": "p2/%package%.json", "available-packages": ["acme/x"], "available-package-patterns": ["other/*"]});
        let base = Url::parse("https://static.example.com/skills/packages.json").unwrap();
        assert_eq!(metadata_url(&root, &base, "acme/x").unwrap().unwrap().as_str(), "https://static.example.com/skills/p2/acme/x.json");
        assert!(metadata_url(&root, &base, "other/y").unwrap().is_some());
        assert!(metadata_url(&root, &base, "acme/nope").unwrap().is_none());
        assert!(metadata_url(&json!({}), &base, "acme/x").is_err());
        assert!(metadata_url(&json!({"packages": {"acme/y": {}}}), &base, "acme/x").unwrap().is_none());
        let packagist = Repository { name: "packagist".into(), url: crate::manifest::PACKAGIST_URL.into(), ..Default::default() };
        assert_eq!(packages_url(&packagist).unwrap().as_str(), "https://repo.packagist.org/packages.json");
        assert!(is_packagist(&packagist));
        let raw = "https://git.example.com/api/v4/projects/7/repository/files/composer%2Fpackages.json/raw?ref=main";
        assert_eq!(packages_url(&Repository { name: "r".into(), url: raw.into(), ..Default::default() }).unwrap().as_str(), raw);
        assert!(glob("a*c", "abbc") && glob("*", "x") && !glob("a*c", "abd") && glob("v/*", "v/x"));
    }
}
