//! Policy layers (D18): environment, enforced keys of the user `config.toml`, the manifest's
//! `[policy]`, the rest of `config.toml`, built-in defaults.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use jiff::SignedDuration;
use toml_edit::{DocumentMut, Item, TableLike};

use crate::bail;
use crate::error::{Context, Error, MANIFEST, Result};

pub const CONFIG: &str = "config.toml";
pub const SKILLS_SH: &str = "skills-sh";
pub const REPOSITORY_AGES: &str = "repository-min-release-age";
pub const KEYS: [&str; 7] =
    ["min-release-age", "allow-ranges", "packagist", "github-requires", "allow-sources", "deny-patterns", "deny-packages"];

#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Age(SignedDuration),
    Bool(bool),
    List(Vec<String>),
}

impl std::fmt::Display for Value {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Value::Age(a) => write!(f, "\"{a:#}\""),
            Value::Bool(b) => write!(f, "{b}"),
            Value::List(l) => {
                // Shown in `status` and warnings; a URL prefix may carry a token.
                let shown = |s: &String| url::Url::parse(s).map_or_else(|_| s.clone(), |u| crate::http::redact(&u));
                write!(f, "[{}]", l.iter().map(|s| format!("{:?}", shown(s))).collect::<Vec<_>>().join(", "))
            }
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Layer {
    pub values: BTreeMap<&'static str, Value>,
    pub enforce: BTreeSet<&'static str>,
    /// `config.toml` only: URL prefix to the cooldown an enforced `min-release-age` allows for
    /// repositories under it (D28).
    pub repository_ages: BTreeMap<String, SignedDuration>,
}

/// The layers around a manifest: the user config and the environment.
#[derive(Clone, Debug, Default)]
pub struct Outer {
    pub config: Layer,
    /// Shown in messages; empty when there is no config file.
    pub config_path: String,
    pub env: Layer,
    /// `[agents] targets` of `config.toml` (D29).
    pub targets: Option<Vec<String>>,
    /// `[search] skills-sh` of `config.toml` (D42); `None`: never decided.
    pub skills_sh: Option<bool>,
}

/// Each key that is set, its value and the layer it came from.
pub type Effective = BTreeMap<&'static str, (Value, &'static str)>;

fn key(k: &str) -> Option<&'static str> {
    KEYS.iter().copied().find(|x| *x == k)
}

/// A `[repositories]` key, and so an `allow-sources` name entry: ASCII letters, digits and `-_.`.
pub fn valid_name(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
}

/// One `allow-sources` entry: `packagist`, `github`, an `https://` prefix, or (with `names`) a
/// repository name, checked against `[repositories]` by the manifest.
fn check_source(s: &str, names: bool) -> std::result::Result<(), String> {
    let name = valid_name(s);
    if matches!(s, "packagist" | "github") || names && name {
        return Ok(());
    }
    if s.starts_with("https://") {
        // Prefix or exact URL is decided on the raw text (`/` at the end), matching on the parsed
        // URL: the two agree only when parsing changes nothing. A stray space, `\`, `?` or `#`
        // would otherwise read as an exact registry URL and still match as a prefix.
        let u = url::Url::parse(s).map_err(|e| format!("{s:?}: {e}"))?;
        if u.query().is_some() || u.fragment().is_some() {
            return Err(format!("{s:?}: an allow-sources URL takes no ? or #"));
        }
        let canonical = u.as_str();
        if canonical != s && canonical != format!("{s}/") {
            return Err(format!("{s:?} is not written as its URL; use {canonical:?}"));
        }
        return Ok(());
    }
    Err(if name {
        format!("{s:?}: repository names are only accepted in skills.toml; use packagist, github or an https:// URL prefix")
    } else {
        format!("{s:?} is not packagist, github, an https:// URL prefix or a repository name")
    })
}

/// `vendor/name` or `vendor/*`, each part as a package name allows it (lowercase).
fn valid_package_pattern(p: &str) -> bool {
    p.split_once('/').is_some_and(|(v, n)| crate::manifest::valid_package_name(&format!("{v}/{}", if n == "*" { "x" } else { n })))
}

/// Whether package `name` (`vendor/name`) matches a `deny-packages` entry (D57).
pub fn denied(patterns: &[String], name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    patterns.iter().any(|p| p.strip_suffix("/*").map_or(*p == name, |v| name.split_once('/').is_some_and(|(nv, _)| nv == v)))
}

fn value(k: &'static str, raw: Raw, names: bool) -> std::result::Result<Value, String> {
    match (k, raw) {
        ("min-release-age", Raw::Str(s)) => crate::manifest::duration(&s).map(Value::Age),
        ("min-release-age", _) => Err("must be a string such as \"3d\"".into()),
        ("allow-sources", Raw::List(l)) => {
            l.iter().try_for_each(|s| check_source(s, names))?;
            Ok(Value::List(l))
        }
        // Matching ignores case, so the entries are read as lowercase.
        ("deny-packages", Raw::List(l)) => {
            let l: Vec<String> = l.iter().map(|p| p.to_ascii_lowercase()).collect();
            match l.iter().find(|p| !valid_package_pattern(p)) {
                Some(p) => Err(format!("{p:?} is not vendor/name or vendor/*")),
                None => Ok(Value::List(l)),
            }
        }
        ("allow-sources" | "deny-packages", _) => Err("must be a list".into()),
        (_, Raw::Bool(b)) => Ok(Value::Bool(b)),
        (_, Raw::Str(s)) if s == "true" || s == "false" => Ok(Value::Bool(s == "true")),
        _ => Err("must be true or false".into()),
    }
}

enum Raw {
    Str(String),
    Bool(bool),
    List(Vec<String>),
}

fn raw(i: &Item) -> Option<Raw> {
    if let Some(s) = i.as_str() {
        return Some(Raw::Str(s.into()));
    }
    if let Some(b) = i.as_bool() {
        return Some(Raw::Bool(b));
    }
    i.as_array()?.iter().map(|v| v.as_str().map(String::from)).collect::<Option<Vec<_>>>().map(Raw::List)
}

/// `[policy]` of a manifest (`config = false`: unknown keys are left to other versions) or of
/// `config.toml` (`config = true`: `enforce` allowed, unknown keys and repository names refused).
pub fn layer(t: Option<&dyn TableLike>, file: &str, config: bool) -> Result<Layer> {
    let bad = |k: &str, e: String| Error::new(MANIFEST, format!("{file}: policy.{k} {e}"));
    let mut out = Layer::default();
    let Some(t) = t else { return Ok(out) };
    for (k, item) in t.iter() {
        if config && k == "enforce" {
            for e in
                raw(item).and_then(|r| if let Raw::List(l) = r { Some(l) } else { None }).ok_or_else(|| bad(k, "must be a list".into()))?
            {
                out.enforce.insert(key(&e).ok_or_else(|| bad(k, format!("names unknown key {e:?}")))?);
            }
            continue;
        }
        if config && k == REPOSITORY_AGES {
            let t = item.as_table_like().ok_or_else(|| bad(k, "must be a table of URL prefix = age".into()))?;
            for (prefix, age) in t.iter() {
                if !prefix.starts_with("https://") || prefix.len() == "https://".len() {
                    return Err(bad(k, format!("{prefix:?} is not an https:// URL prefix")));
                }
                let age = age.as_str().ok_or_else(|| bad(k, format!("{prefix:?} must be a string such as \"3d\"")))?;
                let age = crate::manifest::duration(age).map_err(|e| bad(k, format!("{prefix:?}: {e}")))?;
                out.repository_ages.insert(prefix.to_string(), age);
            }
            continue;
        }
        let Some(k) = key(k) else {
            if config {
                bail!(MANIFEST, "{file}: unknown key policy.{k}");
            }
            continue;
        };
        let v = raw(item).ok_or_else(|| bad(k, "has an unsupported type".into()))?;
        out.values.insert(k, value(k, v, !config).map_err(|e| bad(k, e))?);
    }
    if let Some(k) = out.enforce.iter().find(|k| !out.values.contains_key(*k)) {
        bail!(MANIFEST, "{file}: policy.enforce lists {k}, which policy does not set");
    }
    if !out.repository_ages.is_empty() && !out.enforce.contains("min-release-age") {
        bail!(MANIFEST, "{file}: policy.{REPOSITORY_AGES} needs min-release-age in policy.enforce");
    }
    Ok(out)
}

/// `SKILLCASK_MIN_RELEASE_AGE` etc.; empty counts as unset, lists are comma-separated.
pub fn env_layer(var: impl Fn(&str) -> Option<String>) -> Result<Layer> {
    let mut out = Layer::default();
    for k in KEYS {
        let name = format!("SKILLCASK_{}", k.to_uppercase().replace('-', "_"));
        let Some(s) = var(&name).filter(|s| !s.trim().is_empty()) else { continue };
        let r = if matches!(k, "allow-sources" | "deny-packages") {
            Raw::List(s.split(',').map(str::trim).filter(|x| !x.is_empty()).map(String::from).collect())
        } else {
            Raw::Str(s.trim().to_string())
        };
        out.values.insert(k, value(k, r, false).map_err(|e| Error::new(MANIFEST, format!("{name} {e}")))?);
    }
    Ok(out)
}

/// The user config next to the global manifest, and the environment.
pub fn outer() -> Result<Outer> {
    let env = env_layer(|k| std::env::var(k).ok())?;
    let Some(path) = crate::scope::config_dir().map(|d| d.join(CONFIG)) else {
        return Ok(Outer { env, ..Default::default() });
    };
    Ok(Outer { env, ..read_config(&path)? })
}

fn read_config(path: &Path) -> Result<Outer> {
    let shown = path.display().to_string();
    match std::fs::read_to_string(path) {
        Ok(t) => parse_config(&t, &shown),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Outer::default()),
        Err(e) => Err(e).ctx(&shown),
    }
}

pub fn parse_config(text: &str, shown: &str) -> Result<Outer> {
    let doc: DocumentMut = text.parse().map_err(|e| Error::new(MANIFEST, format!("{shown}: {e}")))?;
    if let Some((k, _)) = doc.iter().find(|(k, _)| !matches!(*k, "policy" | "agents" | "search")) {
        bail!(MANIFEST, "{shown}: only [policy], [agents] and [search] are read here, found {k}");
    }
    let mut skills_sh = None;
    if let Some(s) = doc.get("search") {
        let s = s.as_table_like().ok_or_else(|| Error::new(MANIFEST, format!("{shown}: search must be a table")))?;
        for (k, item) in s.iter() {
            if k != SKILLS_SH {
                bail!(MANIFEST, "{shown}: search.{k} is not read here, only search.{SKILLS_SH}");
            }
            skills_sh = Some(item.as_bool().ok_or_else(|| Error::new(MANIFEST, format!("{shown}: search.{k} must be true or false")))?);
        }
    }
    let mut targets = None;
    if let Some(a) = doc.get("agents") {
        let a = a.as_table_like().ok_or_else(|| Error::new(MANIFEST, format!("{shown}: agents must be a table")))?;
        for (k, item) in a.iter() {
            if k != "targets" {
                bail!(MANIFEST, "{shown}: agents.{k} is not read here, only agents.targets");
            }
            let list = item.as_array().and_then(|l| l.iter().map(|v| v.as_str().map(String::from)).collect::<Option<Vec<_>>>());
            targets =
                Some(list.ok_or_else(|| Error::new(MANIFEST, format!("{shown}: agents.targets must be a list of agent names or paths")))?);
        }
    }
    let config = layer(doc.get("policy").and_then(Item::as_table_like), shown, true)?;
    Ok(Outer { config, config_path: shown.to_string(), env: Layer::default(), targets, skills_sh })
}

/// `config.toml` in the user's config dir, which need not exist yet.
pub fn config_path() -> Result<std::path::PathBuf> {
    match crate::scope::config_dir() {
        Some(d) => Ok(d.join(CONFIG)),
        None => bail!(MANIFEST, "{CONFIG} needs HOME (or USERPROFILE) to be set"),
    }
}

/// Applies `f` to `config.toml`, keeping the rest of the file, and writes it only if the result is
/// valid, also as the layer under an empty project; returns its path.
pub fn edit_config(f: impl FnOnce(&mut DocumentMut) -> Result<()>) -> Result<std::path::PathBuf> {
    let path = config_path()?;
    let shown = path.display().to_string();
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(e).ctx(&shown),
    };
    let mut doc: DocumentMut = text.parse().map_err(|e| Error::new(MANIFEST, format!("{shown}: {e}")))?;
    f(&mut doc)?;
    let text = doc.to_string();
    // Targets are only checked against the presets when a manifest uses them.
    crate::manifest::parse_with("", false, &parse_config(&text, &shown)?)?;
    crate::project::write_atomic(&path, &text)?;
    Ok(path)
}

/// Writes `[search] skills-sh` into `config.toml`; returns its path.
pub fn remember_skills_sh(on: bool) -> Result<std::path::PathBuf> {
    edit_config(|doc| {
        let search = doc.entry("search").or_insert_with(toml_edit::table);
        let Some(search) = search.as_table_like_mut() else { bail!(MANIFEST, "search must be a table") };
        search.insert(SKILLS_SH, toml_edit::value(on));
        Ok(())
    })
}

/// Layer names `resolve` records and `fixed` matches.
pub const ENVIRONMENT: &str = "environment";
pub const ENFORCED: &str = "config.toml, enforced";

/// An entry of an enforced `allow-sources` as the URL prefix it stands for; `github` is public
/// GitHub, which `SKILLCASK_GITHUB_API` and `GITHUB_API_URL` cannot move (D43).
fn source_url(entry: &str) -> String {
    match entry {
        "packagist" => crate::manifest::PACKAGIST_URL.to_string(),
        "github" => format!("{}/repos/", crate::github::API),
        e => e.to_string(),
    }
}

/// Whether the environment's `v` asks at least what the enforced `e` asks (D18): a cooldown as
/// long, `deny-patterns` on if it is on, `allow-ranges`, `packagist` and `github-requires` off if
/// they are off, and only sources inside the enforced `allow-sources`.
pub fn tightens(k: &str, v: &Value, e: &Value) -> bool {
    match (v, e) {
        (Value::Age(v), Value::Age(e)) => v >= e,
        (Value::Bool(v), Value::Bool(e)) if k == "deny-patterns" => v >= e,
        (Value::Bool(v), Value::Bool(e)) => v <= e,
        // A deny list tightens by denying at least everything the enforced one does.
        (Value::List(v), Value::List(e)) if k == "deny-packages" => e.iter().all(|y| denied(v, y)),
        (Value::List(v), Value::List(e)) => v.iter().all(|x| e.iter().any(|y| x == y || under(&source_url(x), &source_url(y)))),
        _ => false,
    }
}

/// Merges the layers; a manifest value that differs from an enforced one is an error, and so is
/// an environment value that loosens one.
pub fn resolve(project: &Layer, o: &Outer) -> Result<Effective> {
    let mut out = Effective::new();
    for k in KEYS {
        let enforced = o.config.enforce.contains(k).then(|| o.config.values.get(k)).flatten();
        if let (Some(e), Some(v)) = (enforced, o.env.values.get(k))
            && !tightens(k, v, e)
        {
            let var = format!("SKILLCASK_{}", k.to_uppercase().replace('-', "_"));
            return Err(Error::new(MANIFEST, format!("{var} = {v} loosens policy.{k} = {e} enforced by {}", o.config_path))
                .hint(format!("unset {var} or make it stricter, or ask whoever manages {} to lift it", o.config_path)));
        }
        // With the key in the environment the project's value is unused, so it cannot clash.
        // A project may add to an enforced deny list (D57), not change any other enforced key.
        if let (Some(e), Some(p), None) = (enforced, project.values.get(k), o.env.values.get(k))
            && if k == "deny-packages" { !tightens(k, p, e) } else { e != p }
        {
            return Err(Error::new(MANIFEST, format!("policy.{k} is enforced as {e} by {}", o.config_path)).hint(format!(
                "remove policy.{k} from {}, or ask whoever manages {} to lift it",
                crate::manifest::FILE,
                o.config_path
            )));
        }
        // The environment repeating the enforced value changes nothing: it stays enforced.
        let pick = if let Some(v) = o.env.values.get(k).filter(|v| enforced != Some(*v)) {
            Some((v, ENVIRONMENT))
        } else if let Some(v) = enforced {
            let added = project.values.get(k).filter(|p| k == "deny-packages" && tightens(k, p, v));
            Some((added.unwrap_or(v), ENFORCED))
        } else if let Some(v) = project.values.get(k) {
            Some((v, "skills.toml"))
        } else {
            o.config.values.get(k).map(|v| (v, "config.toml"))
        };
        if let Some((v, from)) = pick {
            out.insert(k, (v.clone(), from));
        }
    }
    Ok(out)
}

/// Whether `k` comes from a layer the project cannot loosen: the environment or an enforced key.
pub fn fixed(e: &Effective, k: &str) -> bool {
    matches!(e.get(k), Some((_, ENVIRONMENT | ENFORCED)))
}

/// With `min-release-age` enforced, the shortest cooldown a project may give the repository at
/// `url`: the longest matching prefix of `repository-min-release-age`, else the enforced value.
pub fn repository_floor(o: &Outer, url: &str, enforced: SignedDuration) -> SignedDuration {
    o.config.repository_ages.iter().filter(|(p, _)| under(url, p)).max_by_key(|(p, _)| p.len()).map_or(enforced, |(_, a)| *a)
}

/// `url` is `prefix` or below it on a `/` (or query) boundary, both compared as parsed URLs, as the
/// request is made: scheme, host and port equal, `..`, `%2e%2e` and `\` already resolved. Below the
/// prefix a `..` behind `%2F` or `%5C`, or with a path parameter (`..;v=1`), is refused too, for
/// servers that decode or strip parameters before resolving. A prefix with a query matches only
/// itself; a side that does not parse matches nothing.
pub fn under(url: &str, prefix: &str) -> bool {
    let (Ok(u), Ok(p)) = (url::Url::parse(url), url::Url::parse(prefix)) else { return false };
    if u.origin() != p.origin() {
        return false;
    }
    if p.query().is_some() {
        return u.as_str() == p.as_str();
    }
    let (path, base) = (u.path(), p.path());
    let inside = path == base || path.starts_with(base) && (base.ends_with('/') || path[base.len()..].starts_with('/'));
    let dotdot = |s: &str| s.split(';').next() == Some("..");
    inside && !percent_encoding::percent_decode_str(&path[base.len()..]).decode_utf8_lossy().split(['/', '\\']).any(dotdot)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Regression: `"https://h/acme/ "` parsed as the prefix `https://h/acme/`, while the lock dist
    // rule read it as an exact registry URL and accepted that registry's dists from any host.
    #[test]
    fn an_allow_sources_url_must_be_written_as_it_parses() {
        for ok in ["https://h/acme/", "https://h/acme", "https://h", "https://h/", "https://h:8443/a/"] {
            assert_eq!(check_source(ok, false), Ok(()), "{ok}");
        }
        for bad in [
            "https://h/acme/ ",
            "https://h/acme/\t",
            "https://h/acme/\r",
            " https://h/acme/",
            "https://h/acme/?",
            "https://h/acme/#",
            "https://h/acme/?x=1",
            "https://h/acme/\u{200B}",
            "https://h/acme\\",
            "https://H/acme/",
            "https://h/a/../acme/",
            "https://h:443/acme/",
        ] {
            assert!(check_source(bad, false).is_err(), "{bad:?}");
        }
        assert!(check_source("https://H/acme/", false).unwrap_err().contains("use \"https://h/acme/\""));
    }

    #[test]
    fn the_environment_may_only_tighten_an_enforced_value() {
        let age = |s: &str| Value::Age(crate::manifest::duration(s).unwrap());
        let list = |l: &[&str]| Value::List(l.iter().map(|s| s.to_string()).collect());
        assert!(tightens("min-release-age", &age("5d"), &age("3d")) && tightens("min-release-age", &age("3d"), &age("3d")));
        assert!(!tightens("min-release-age", &age("0"), &age("3d")));
        assert!(tightens("deny-patterns", &Value::Bool(true), &Value::Bool(false)));
        assert!(!tightens("deny-patterns", &Value::Bool(false), &Value::Bool(true)));
        for k in ["allow-ranges", "packagist", "github-requires"] {
            assert!(tightens(k, &Value::Bool(false), &Value::Bool(true)), "{k}");
            assert!(!tightens(k, &Value::Bool(true), &Value::Bool(false)), "{k}");
        }
        let enforced = list(&["https://gitlab.example.com/", "github"]);
        assert!(tightens("allow-sources", &list(&["https://gitlab.example.com/skills/"]), &enforced));
        assert!(tightens("allow-sources", &list(&["https://api.github.com/repos/acme/"]), &enforced));
        assert!(tightens("allow-sources", &list(&[]), &enforced));
        assert!(!tightens("allow-sources", &list(&["packagist"]), &enforced));
        assert!(!tightens("allow-sources", &list(&["https://gitlab.example.com.evil/"]), &enforced));
        assert!(tightens("allow-sources", &list(&["packagist"]), &list(&["https://repo.packagist.org/"])));
    }

    fn cfg(text: &str) -> Result<Layer> {
        let doc: DocumentMut = text.parse().unwrap();
        layer(doc.get("policy").and_then(Item::as_table_like), "config.toml", true)
    }

    fn proj(text: &str) -> Layer {
        let doc: DocumentMut = text.parse().unwrap();
        layer(doc.get("policy").and_then(Item::as_table_like), "skills.toml", false).unwrap()
    }

    #[test]
    fn layers_in_order() {
        let config = cfg("[policy]\nallow-sources = [\"https://git.example.com/\"]\nmin-release-age = \"1d\"\nallow-ranges = false\nenforce = [\"allow-sources\"]").unwrap();
        let o = Outer { config, config_path: "config.toml".into(), ..Default::default() };
        let p = proj("[policy]\nmin-release-age = \"2d\"");
        let e = resolve(&p, &o).unwrap();
        assert_eq!(e["min-release-age"], (Value::Age(SignedDuration::from_hours(48)), "skills.toml"));
        assert_eq!(e["allow-ranges"], (Value::Bool(false), "config.toml"));
        assert_eq!(e["allow-sources"].1, "config.toml, enforced");
        assert!(!e.contains_key("packagist"));

        let clash = proj("[policy]\nallow-sources = [\"acme\"]");
        assert!(resolve(&clash, &o).unwrap_err().msg.contains("policy.allow-sources is enforced"));
        let same = proj("[policy]\nallow-sources = [\"https://git.example.com/\"]");
        assert!(resolve(&same, &o).is_ok());

        // The environment may narrow an enforced key, never widen it (D18).
        let env = |v: &str| env_layer(|k| (k == "SKILLCASK_ALLOW_SOURCES").then(|| v.to_string())).unwrap();
        let wide = resolve(&clash, &Outer { env: env("github, packagist"), ..o.clone() }).unwrap_err();
        assert!(wide.msg.contains("SKILLCASK_ALLOW_SOURCES = [\"github\", \"packagist\"] loosens policy.allow-sources"), "{}", wide.msg);
        let e = resolve(&clash, &Outer { env: env("https://git.example.com/skills/"), ..o }).unwrap();
        assert_eq!(e["allow-sources"], (Value::List(vec!["https://git.example.com/skills/".into()]), "environment"));
    }

    #[test]
    fn rejects_bad_config() {
        assert!(cfg("[policy]\nallow-sources = [\"acme\"]").unwrap_err().msg.contains("only accepted in skills.toml"));
        assert!(cfg("[policy]\nallow-ranges = 1").is_err());
        assert!(cfg("[policy]\nallow-sources = [\"https://exa mple.com/\"]").is_err());
        assert!(cfg("[policy]\nmin-release-age = 3").is_err());
        assert!(cfg("[policy]\ntypo = true").unwrap_err().msg.contains("unknown key"));
        assert!(cfg("[policy]\nenforce = [\"packagist\"]").unwrap_err().msg.contains("does not set"));
        assert!(cfg("[policy]\nenforce = [\"nope\"]").is_err());
        let ages = "[policy]\nmin-release-age = \"1d\"\n[policy.repository-min-release-age]\n";
        assert!(cfg(&format!("{ages}\"https://a/\" = \"0\"")).unwrap_err().msg.contains("needs min-release-age in policy.enforce"));
        let ages = ages.replace("\n[", "\nenforce = [\"min-release-age\"]\n[");
        assert!(cfg(&format!("{ages}\"https://a/\" = \"0\"")).is_ok());
        assert!(cfg(&format!("{ages}acme = \"0\"")).unwrap_err().msg.contains("not an https:// URL prefix"));
        assert!(cfg(&format!("{ages}\"https://a/\" = 0")).is_err());
        assert!(proj("[policy]\ntypo = true").values.is_empty());
        assert!(env_layer(|k| (k == "SKILLCASK_ALLOW_RANGES").then(|| "yes".to_string())).is_err());
        assert!(env_layer(|_| Some(" ".into())).unwrap().values.is_empty());
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join(CONFIG), "[repositories]\nx = 1\n").unwrap();
        assert!(read_config(&dir.path().join(CONFIG)).unwrap_err().msg.contains("only [policy], [agents] and [search]"));
        assert_eq!(read_config(&dir.path().join("missing.toml")).unwrap().config, Layer::default());
        std::fs::write(dir.path().join(CONFIG), "[agents]\ntargets = [\"claude\", \"./x\"]\n").unwrap();
        assert_eq!(read_config(&dir.path().join(CONFIG)).unwrap().targets, Some(vec!["claude".into(), "./x".into()]));
        std::fs::write(dir.path().join(CONFIG), "[agents]\nlocal = \".skills\"\n").unwrap();
        assert!(read_config(&dir.path().join(CONFIG)).unwrap_err().msg.contains("agents.local is not read here"));
        std::fs::write(dir.path().join(CONFIG), "[search]\nskills-sh = \"yes\"\n").unwrap();
        assert!(read_config(&dir.path().join(CONFIG)).unwrap_err().msg.contains("search.skills-sh must be true or false"));
        std::fs::write(dir.path().join(CONFIG), "[search]\nskills-sh = false\n").unwrap();
        assert_eq!(read_config(&dir.path().join(CONFIG)).unwrap().skills_sh, Some(false));
    }

    #[test]
    fn deny_packages() {
        assert!(proj("[policy]\ndeny-packages = [\"evil/*\", \"acme/bad\"]").values.contains_key("deny-packages"));
        // Entries no valid package name can match are refused, not left to never fire.
        for bad in ["evil", "*/x", "evil/x*", "/x", "evil/", "acme/-x", "a./b", "evil./*"] {
            let doc: DocumentMut = format!("[policy]\ndeny-packages = [{bad:?}]").parse().unwrap();
            assert!(layer(doc.get("policy").and_then(Item::as_table_like), "skills.toml", false).is_err(), "{bad}");
        }
        assert_eq!(
            proj("[policy]\ndeny-packages = [\"Evil/X\"]").values["deny-packages"],
            Value::List(vec!["evil/x".into()]),
            "read as lowercase"
        );
        let l = vec!["evil/*".to_string(), "acme/bad".to_string()];
        assert!(denied(&l, "evil/x") && denied(&l, "Acme/Bad") && !denied(&l, "acme/good") && !denied(&l, "evilx/y"));
        let env = env_layer(|k| (k == "SKILLCASK_DENY_PACKAGES").then(|| "evil/*, acme/bad".to_string())).unwrap();
        assert_eq!(env.values["deny-packages"], Value::List(l));

        // Enforced, the list is a floor: a project or the environment may add to it, in any order.
        let config = cfg("[policy]\ndeny-packages = [\"evil/*\"]\nenforce = [\"deny-packages\"]").unwrap();
        let o = Outer { config, config_path: "config.toml".into(), ..Default::default() };
        let more = proj("[policy]\ndeny-packages = [\"acme/bad\", \"evil/*\"]");
        assert_eq!(resolve(&more, &o).unwrap()["deny-packages"], (Value::List(vec!["acme/bad".into(), "evil/*".into()]), ENFORCED));
        let fewer = resolve(&proj("[policy]\ndeny-packages = [\"evil/x\"]"), &o).unwrap_err();
        assert!(fewer.msg.contains("policy.deny-packages is enforced as [\"evil/*\"]"), "{}", fewer.msg);
        let env = |v: &str| env_layer(|k| (k == "SKILLCASK_DENY_PACKAGES").then(|| v.to_string())).unwrap();
        assert!(resolve(&proj(""), &Outer { env: env("evil/*, acme/bad"), ..o.clone() }).is_ok());
        assert!(resolve(&proj(""), &Outer { env: env(","), ..o }).unwrap_err().msg.contains("SKILLCASK_DENY_PACKAGES = [] loosens"));
    }

    #[test]
    fn shown_values_hide_credentials() {
        let v = Value::List(vec!["github".into(), "https://user:s3cret@git.example.com/x?private_token=t0k".into()]);
        let shown = v.to_string();
        assert!(!shown.contains("s3cret") && !shown.contains("t0k") && !shown.contains("user"), "{shown}");
        assert!(shown.contains("\"github\"") && shown.contains("git.example.com/x"), "{shown}");
    }

    #[test]
    fn prefix_boundary() {
        assert!(under("https://git.example.com/a/packages.json", "https://git.example.com"));
        assert!(under("https://git.example.com/a", "https://git.example.com/"));
        assert!(!under("https://git.example.com.evil/a", "https://git.example.com"));
        assert!(!under("https://api.github.com/repos/acmex/r", "https://api.github.com/repos/acme"));
        assert!(under("https://api.github.com/repos/acme/r", "https://api.github.com/repos/acme"));
        assert!(under("https://git.example.com/raw?ref=main", "https://git.example.com/raw"));
        assert!(under("https://GIT.example.com:443/a", "https://git.example.com/"));
        assert!(!under("https://git.example.com:8443/a", "https://git.example.com/"));
        assert!(!under("not a url", "https://git.example.com/"));
    }

    #[test]
    fn dot_segments_do_not_escape_a_prefix() {
        let allowed = "https://git.example.com/api/v4/group/42/";
        for escape in [
            "../../projects/666/packages.json",
            "%2e%2e/%2E%2E/projects/666/",
            ".%2e/x",
            "a/..\\..\\..\\x",
            "..%2F..%2Fx",
            "..%5cx",
            "%2e%2e%2fx",
            "..;/x",
            "a/..;v=1/..;/x",
            "%2e%2e;%2fx",
        ] {
            assert!(!under(&format!("{allowed}{escape}"), allowed), "{escape}");
        }
        assert!(under(&format!("{allowed}a/../b/packages.json"), allowed));
        assert!(under("https://git.example.com/api/v4/projects/group%2Fproj/packages.json", "https://git.example.com/api/v4/"));
    }
}
