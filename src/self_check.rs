//! `self-check` (D51): whether a newer skillcask is released, read from the tap's cask file.

use std::cmp::Ordering;

use serde_json::json;

use crate::error::{Error, NETWORK, Result};
use crate::ui;

const URL: &str = "https://raw.githubusercontent.com/GetResponse/homebrew-tap/main/Casks/skillcask-app.rb";
const LIMIT: u64 = 64 * 1024;
pub const RUNNING: &str = env!("CARGO_PKG_VERSION");
pub const RELEASES: &str = "https://github.com/GetResponse/skillcask/releases";

/// One anonymous request; writes nothing. Every failure to fetch is a network error (exit 3).
pub fn run(verbose: bool, json: bool) -> Result<()> {
    let latest = latest_release(verbose)?;
    let newer = latest.as_deref().is_some_and(is_newer);
    if json {
        println!("{}", json!({ "version": RUNNING, "latest": latest, "newer": newer }));
        return Ok(());
    }
    match &latest {
        None => println!("skillcask {RUNNING}, latest unknown"),
        Some(l) if newer => {
            println!("skillcask {RUNNING}, latest {l}: {}", ui::out(ui::Color::Yellow, "update available"));
            ui::note(format!("release: {RELEASES}/tag/v{l}"));
        }
        Some(l) => println!("skillcask {RUNNING}, latest {l}: {}", ui::out(ui::Color::Green, "up to date")),
    }
    Ok(())
}

/// `$var` when set, else `default`; anything but https:// is refused (exit 3).
pub fn https_url(var: &str, default: &str) -> Result<String> {
    let url = std::env::var(var).ok().filter(|u| !u.is_empty()).unwrap_or_else(|| default.into());
    if url::Url::parse(&url).map_or(true, |u| u.scheme() != "https") {
        let shown = crate::http::shown_url(&url);
        return Err(Error::new(NETWORK, format!("refusing non-HTTPS URL {shown}")).hint(format!("{var} must be an https:// URL")));
    }
    Ok(url)
}

/// The released version from the cask, `None` (with a warning) when it cannot be read.
pub fn latest_release(verbose: bool) -> Result<Option<String>> {
    let url = https_url("SKILLCASK_SELF_CHECK_URL", URL)?;
    let shown = crate::http::shown_url(&url);
    let hint = format!("check the connection; releases are listed at {RELEASES}");
    let body = crate::http::Http::anonymous(verbose)?
        .get(&url, LIMIT)
        .map_err(|e| Error { code: NETWORK, hint: Some(hint.clone()), ..e })?
        .ok_or_else(|| Error::new(NETWORK, format!("{shown}: not found")).hint(hint))?;
    let latest = latest(&body);
    if latest.is_none() {
        ui::warn(format!("{shown}: no version \"X.Y.Z\" skillcask can read"));
    }
    Ok(latest)
}

pub fn is_newer(latest: &str) -> bool {
    semver_cmp(latest, RUNNING) == Ordering::Greater
}

/// The cask's `version "X.Y.Z"`. Every line whose first word is `version` must hold the same
/// quoted, strictly formed version; none, a malformed one (`version :latest`) or two different
/// ones (per-architecture blocks) leave the latest unknown rather than guessing.
fn latest(body: &[u8]) -> Option<String> {
    let text = std::str::from_utf8(body).ok()?;
    let mut found: Option<&str> = None;
    for line in text.lines() {
        let Some(rest) = line.trim_start().strip_prefix("version") else { continue };
        if !rest.starts_with([' ', '\t']) {
            continue;
        }
        let v = rest.trim().strip_prefix('"')?.strip_suffix('"')?;
        if !strict(v) || found.is_some_and(|f| f != v) {
            return None;
        }
        found = Some(v);
    }
    found.map(String::from)
}

/// `^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$`
fn strict(v: &str) -> bool {
    let (core, pre) = match v.split_once('-') {
        Some((c, p)) => (c, Some(p)),
        None => (v, None),
    };
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    let parts: Vec<&str> = core.split('.').collect();
    parts.len() == 3
        && parts.iter().all(|p| digits(p))
        && pre.is_none_or(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-'))
}

/// `SemVer` 2.0.0 precedence of two `strict` versions. Numbers compare by value without parsing,
/// so any length is fine.
fn semver_cmp(a: &str, b: &str) -> Ordering {
    let split = |v: &'_ str| -> (Vec<String>, Option<String>) {
        let (core, pre) = v.split_once('-').map_or((v, None), |(c, p)| (c, Some(p.to_string())));
        (core.split('.').map(String::from).collect(), pre)
    };
    let num = |x: &str, y: &str| {
        let (x, y) = (x.trim_start_matches('0'), y.trim_start_matches('0'));
        x.len().cmp(&y.len()).then_with(|| x.cmp(y))
    };
    let ident = |x: &str, y: &str| {
        // A leading zero is not a SemVer number (`01`), so it compares as text, as in the app.
        let n = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()) && (s == "0" || !s.starts_with('0'));
        match (n(x), n(y)) {
            (true, true) => num(x, y),
            (true, false) => Ordering::Less,
            (false, true) => Ordering::Greater,
            (false, false) => x.cmp(y),
        }
    };
    let ((ca, pa), (cb, pb)) = (split(a), split(b));
    let core = ca.iter().zip(&cb).map(|(x, y)| num(x, y)).find(|o| o.is_ne()).unwrap_or(Ordering::Equal);
    core.then_with(|| match (pa, pb) {
        (None, None) => Ordering::Equal,
        (None, Some(_)) => Ordering::Greater,
        (Some(_), None) => Ordering::Less,
        (Some(x), Some(y)) => {
            let (x, y): (Vec<&str>, Vec<&str>) = (x.split('.').collect(), y.split('.').collect());
            x.iter().zip(&y).map(|(i, j)| ident(i, j)).find(|o| o.is_ne()).unwrap_or_else(|| x.len().cmp(&y.len()))
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cask(version_lines: &str) -> Vec<u8> {
        format!("cask \"skillcask-app\" do\n{version_lines}  sha256 \"abc\"\n\n  url \"https://github.com/GetResponse/skillcask/releases/download/v#{{version}}/x.zip\"\n  name \"Skillcask\"\nend\n").into_bytes()
    }

    #[test]
    fn reads_the_cask_version() {
        assert_eq!(latest(&cask("  version \"0.10.2\"\n")).as_deref(), Some("0.10.2"));
        assert_eq!(latest(&cask("\tversion   \"1.0.0-rc.1\"  \n")).as_deref(), Some("1.0.0-rc.1"));
        assert_eq!(latest(b"version \"2.3.4\"\r\n").as_deref(), Some("2.3.4"));
    }

    #[test]
    fn anything_else_leaves_the_latest_unknown() {
        for lines in [
            "",
            "  version :latest\n",
            "  version \"0.10\"\n",
            "  version \"v0.10.2\"\n",
            "  version \"0.10.2+build\"\n",
            "  version \"0.10.2-\"\n",
            "  version \"0.10.2-rc_1\"\n",
            "  version \"0.10.2\" # comment\n",
            "  version '0.10.2'\n",
            "  version \"0.10.2\\e[2J\"\n",
            "  # version \"0.10.2\"\n",
        ] {
            assert_eq!(latest(&cask(lines)), None, "{lines:?}");
        }
        assert_eq!(latest(b"\xff version \"1.0.0\"\n"), None, "not UTF-8");
        assert_eq!(latest(b"<html>Not Found</html>"), None);
        assert_eq!(latest(&cask("  versions \"1.0.0\"\n")), None, "only the word version");
    }

    #[test]
    fn several_version_lines_must_agree() {
        assert_eq!(latest(&cask("  version \"1.0.0\"\n  on_arm do\n    version \"1.0.0\"\n  end\n")).as_deref(), Some("1.0.0"));
        assert_eq!(latest(&cask("  on_arm do\n    version \"1.0.1\"\n  end\n  on_intel do\n    version \"1.0.0\"\n  end\n")), None);
        assert_eq!(latest(&cask("  version \"1.0.0\"\n  version :latest\n")), None);
    }

    #[test]
    fn strict_form() {
        for ok in ["0.0.0", "10.20.30", "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-0.3.7", "1.0.0-x-y.z", "01.2.3"] {
            assert!(strict(ok), "{ok}");
        }
        for bad in ["1.0", "1.0.0.0", "1..0", "a.b.c", "1.0.0-", "1.0.0+b", "1.0.0-a b", " 1.0.0", "1.0.0-ä"] {
            assert!(!strict(bad), "{bad}");
        }
    }

    #[test]
    fn compares_by_semver_precedence() {
        // The order of the SemVer 2.0.0 specification, §11.
        let order = [
            "1.0.0-alpha",
            "1.0.0-alpha.1",
            "1.0.0-alpha.beta",
            "1.0.0-beta",
            "1.0.0-beta.2",
            "1.0.0-beta.11",
            "1.0.0-rc.1",
            "1.0.0",
            "1.0.1",
            "1.2.0",
            "1.10.0",
            "2.0.0",
            "18446744073709551616.0.0",
        ];
        for (i, a) in order.iter().enumerate() {
            for (j, b) in order.iter().enumerate() {
                assert_eq!(semver_cmp(a, b), i.cmp(&j), "{a} vs {b}");
            }
        }
        assert_eq!(semver_cmp("0.10.1", "0.9.9"), Ordering::Greater);
        assert_eq!(semver_cmp("01.0.0", "1.0.0"), Ordering::Equal);
        // `01` is text: after every number, and in ASCII order among text.
        assert_eq!(semver_cmp("1.0.0-rc.01", "1.0.0-rc.2"), Ordering::Greater);
        assert_eq!(semver_cmp("1.0.0-rc.01", "1.0.0-rc.1"), Ordering::Greater);
        assert_eq!(semver_cmp("1.0.0-rc.01", "1.0.0-rc.a"), Ordering::Less);
        assert_eq!(semver_cmp("1.0.0-rc.0", "1.0.0-rc.1"), Ordering::Less);
    }
}
