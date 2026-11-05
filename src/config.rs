//! `skillcask config` (D48): the settings of `skills.toml`, or with `--global` of `config.toml`,
//! read with their origin and changed in place so the rest of the file survives.

use std::path::PathBuf;

use serde_json::json;
use toml_edit::DocumentMut;

use crate::bail;
use crate::error::{Context, Error, IO, MANIFEST, Result};
use crate::manifest::{self, Manifest};
use crate::policy::{self, CONFIG, KEYS, SKILLS_SH, Value};
use crate::scope::Scope;
use crate::ui;

/// Keys only `config.toml` has: a person's choices, not a repository's.
const PERSONAL: [&str; 2] = ["policy.enforce", "search.skills-sh"];
const LISTS: [&str; 4] = ["policy.allow-sources", "policy.deny-packages", "policy.enforce", "agents.targets"];

/// A key, its value (`None`: not set) and the layer it came from.
type Setting = (String, Option<Value>, &'static str);

pub fn run(s: &Scope, key: Option<&str>, values: &[String], unset: bool, json: bool) -> Result<()> {
    let Some(k) = key else { return list(s, json) };
    if k == "edit" && values.is_empty() && !unset {
        return edit(s);
    }
    check_key(s, k, values, unset)?;
    if unset || !values.is_empty() { set(s, k, (!unset).then_some(values)) } else { get(s, k, json) }
}

fn check_key(s: &Scope, k: &str, values: &[String], unset: bool) -> Result<()> {
    let project_keys = || KEYS.iter().map(|k| format!("policy.{k}")).chain(["agents.targets".to_string()]);
    if !project_keys().any(|x| x == k) && !PERSONAL.contains(&k) {
        return Err(Error::new(MANIFEST, format!("unknown key {k:?}")).hint(format!(
            "keys: {}; with -g also {}; [repositories] through skillcask repository, other tables through skillcask config edit",
            project_keys().collect::<Vec<_>>().join(", "),
            PERSONAL.join(", ")
        )));
    }
    if PERSONAL.contains(&k) && !s.global {
        let mut cmd = vec!["skillcask -g config".to_string()];
        cmd.extend(unset.then(|| "--unset".to_string()));
        cmd.push(k.to_string());
        cmd.extend(values.iter().cloned());
        return Err(
            Error::new(MANIFEST, format!("{k} is a personal setting, kept in {CONFIG}, not {}", manifest::FILE)).hint(cmd.join(" "))
        );
    }
    Ok(())
}

/// The file `config` reads and writes.
fn file(s: &Scope) -> Result<PathBuf> {
    if s.global { policy::config_path() } else { Ok(s.config.join(manifest::FILE)) }
}

/// `file` as messages name it.
fn shown(s: &Scope) -> Result<String> {
    if s.global { Ok(policy::config_path()?.display().to_string()) } else { Ok(manifest::FILE.to_string()) }
}

fn need_manifest(s: &Scope) -> Result<()> {
    if s.global || s.config.join(manifest::FILE).is_file() {
        return Ok(());
    }
    Err(Error::new(MANIFEST, format!("{} not found", manifest::FILE)).hint("run skillcask init, or use -g for config.toml"))
}

fn settings(s: &Scope) -> Result<Vec<Setting>> {
    let outer = policy::outer()?;
    let m = if s.global { manifest::parse_with("", false, &outer)? } else { Manifest::load(&s.config, false)? };
    let mut out: Vec<Setting> = KEYS
        .iter()
        .map(|k| match m.policy.effective.get(k) {
            Some((v, from)) => (format!("policy.{k}"), Some(v.clone()), *from),
            None => (format!("policy.{k}"), default(&m.policy, k), "default"),
        })
        .collect();
    if s.global {
        let enforce: Vec<String> = outer.config.enforce.iter().map(|k| k.to_string()).collect();
        out.push(("policy.enforce".into(), (!enforce.is_empty()).then_some(Value::List(enforce)), CONFIG));
    }
    out.push(("agents.targets".into(), Some(Value::List(m.target_entries.clone())), m.targets_from));
    out.push((format!("search.{SKILLS_SH}"), outer.skills_sh.map(Value::Bool), CONFIG));
    Ok(out)
}

/// The built-in value of a key no layer sets.
fn default(p: &manifest::Policy, k: &str) -> Option<Value> {
    Some(match k {
        "min-release-age" => Value::Age(p.min_release_age),
        "allow-ranges" => Value::Bool(p.allow_ranges),
        "packagist" => Value::Bool(p.packagist),
        "github-requires" => Value::Bool(p.github_requires),
        "deny-patterns" => Value::Bool(p.deny_patterns),
        _ => return None,
    })
}

fn list(s: &Scope, json: bool) -> Result<()> {
    need_manifest(s)?;
    let all = settings(s)?;
    if json {
        let settings: serde_json::Map<String, serde_json::Value> = all
            .iter()
            .map(|(k, v, from)| {
                (k.clone(), json!({ "value": v.as_ref().map(crate::commands::policy_value), "from": v.as_ref().map(|_| from) }))
            })
            .collect();
        println!("{}", json!({ "file": file(s)?.display().to_string(), "settings": settings }));
        return Ok(());
    }
    for (k, v, from) in all {
        match v {
            Some(v) => println!("{k} = {v} ({from})"),
            None => println!("{k} not set"),
        }
    }
    Ok(())
}

fn get(s: &Scope, k: &str, json: bool) -> Result<()> {
    need_manifest(s)?;
    let v = settings(s)?.into_iter().find(|(x, ..)| x == k).and_then(|(_, v, from)| Some((v?, from)));
    if json {
        let (value, from) = v.as_ref().map(|(v, f)| (crate::commands::policy_value(v), *f)).unzip();
        println!("{}", json!({ "value": value, "from": from }));
    } else if let Some((v, _)) = &v {
        println!("{v}");
    }
    if v.is_none() {
        bail!(MANIFEST, "{k} is not set");
    }
    Ok(())
}

fn set(s: &Scope, k: &str, values: Option<&[String]>) -> Result<()> {
    need_manifest(s)?;
    let (table, name) = k.split_once('.').expect("known keys have a table");
    let value = values.map(|v| toml_value(k, v)).transpose()?;
    let apply = |doc: &mut DocumentMut| -> Result<()> {
        if value.is_none() && doc.get(table).is_none() {
            return Ok(());
        }
        let t = doc.entry(table).or_insert_with(toml_edit::table);
        let Some(t) = t.as_table_like_mut() else { bail!(MANIFEST, "{table} must be a table") };
        manifest::set(t, name, value.clone());
        Ok(())
    };
    if s.global {
        policy::edit_config(apply)?;
    } else {
        manifest::edit(&s.config, false, |doc| {
            apply(doc)?;
            // A value an enforced key forbids would break every later command.
            manifest::parse_with(&doc.to_string(), false, &policy::outer()?).map(drop)
        })?;
    }
    let shown = shown(s)?;
    match values {
        Some(_) => ui::done("set", format!("{k} in {shown}")),
        None => ui::done("removed", format!("{k} from {shown}")),
    }
    if let Some((_, Some(v), policy::ENVIRONMENT)) = settings(s)?.into_iter().find(|(x, ..)| x == k) {
        ui::warn(format!("the environment overrides it here: {k} = {v}"));
    }
    Ok(())
}

/// D59: `repository add`. With `--global` a missing `skills.toml` is created from the template, so
/// device management can run it on any machine.
pub fn add_repository(s: &Scope, name: &str, url: &str, min_release_age: Option<&str>) -> Result<()> {
    let mut t = toml_edit::InlineTable::new();
    if name == "github" {
        t.insert("type", "github".into());
    }
    t.insert("url", url.into());
    if let Some(age) = min_release_age {
        t.insert("min-release-age", age.into());
    }
    t.fmt();
    let existed = edit_repositories(s, |r| {
        let existed = r.contains_key(name);
        manifest::set(r, name, Some(toml_edit::Value::InlineTable(t)));
        existed
    })?;
    ui::done(if existed { "replaced" } else { "added" }, format!("repository {name} in {}", manifest_shown(s)));
    Ok(())
}

/// D59: `repository remove`; the default sources have no entry to drop, so they are turned off.
pub fn remove_repository(s: &Scope, name: &str) -> Result<()> {
    let default = matches!(name, "packagist" | "github");
    let existed = edit_repositories(s, |r| {
        let existed = r.contains_key(name);
        manifest::set(r, name, default.then(|| false.into()));
        existed
    })?;
    let shown = manifest_shown(s);
    match (default, existed) {
        (true, _) => ui::done("turned off", format!("repository {name} in {shown}")),
        (false, true) => ui::done("removed", format!("repository {name} from {shown}")),
        (false, false) => ui::note(format!("no repository {name} in {shown}")),
    }
    Ok(())
}

fn edit_repositories<T>(s: &Scope, f: impl FnOnce(&mut dyn toml_edit::TableLike) -> T) -> Result<T> {
    if !s.global {
        need_manifest(s)?;
    }
    let mut out = None;
    manifest::edit(&s.config, s.global, |doc| {
        let r = doc.entry("repositories").or_insert_with(toml_edit::table);
        let Some(r) = r.as_table_like_mut() else { bail!(MANIFEST, "repositories must be a table") };
        out = Some(f(r));
        // An enforced policy may refuse the entry (a cooldown shorter than its floor, D28).
        manifest::parse_with(&doc.to_string(), s.global, &policy::outer()?).map(drop)
    })
    .map_err(|e| e.map_msg(|m| format!("{}: {}", manifest_shown(s), manifest::unprefixed(m))))?;
    Ok(out.expect("edit ran"))
}

fn manifest_shown(s: &Scope) -> String {
    if s.global { s.config.join(manifest::FILE).display().to_string() } else { manifest::FILE.to_string() }
}

/// `true`/`false` as a boolean, a list key as one entry per argument, anything else as a string;
/// the file's own checks then reject a wrong type.
fn toml_value(k: &str, values: &[String]) -> Result<toml_edit::Value> {
    if LISTS.contains(&k) {
        return Ok(toml_edit::Value::Array(values.iter().map(String::as_str).collect()));
    }
    let [v] = values else { bail!(MANIFEST, "{k} takes one value, got {}", values.len()) };
    Ok(match v.as_str() {
        "true" => true.into(),
        "false" => false.into(),
        v => v.into(),
    })
}

/// Opens the file in `$VISUAL` or `$EDITOR` and checks it afterwards; a broken edit stays in the
/// file so it is not lost.
fn edit(s: &Scope) -> Result<()> {
    need_manifest(s)?;
    let path = file(s)?;
    let shown = shown(s)?;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).ctx(dir.display())?;
    }
    let editor = ["VISUAL", "EDITOR"]
        .iter()
        .find_map(|v| std::env::var(v).ok().filter(|e| !e.trim().is_empty()))
        .unwrap_or_else(|| if cfg!(windows) { "notepad" } else { "vi" }.to_string());
    // As in git, the editor is a shell command: `code --wait` works, and a path with spaces is quoted.
    #[cfg(not(windows))]
    let mut cmd = {
        let mut c = std::process::Command::new("sh");
        c.arg("-c").arg(format!("{editor} \"$@\"")).arg(&editor).arg(&path);
        c
    };
    #[cfg(windows)]
    let mut cmd = {
        use std::os::windows::process::CommandExt;
        // `/S` makes cmd drop only the outer quotes and run the rest as typed.
        let mut c = std::process::Command::new("cmd");
        c.raw_arg(format!("/S /C \"{editor} \"{}\"\"", path.display()));
        c
    };
    let status = cmd.status().map_err(|e| Error::new(IO, format!("{editor}: {e}")))?;
    if !status.success() {
        bail!(MANIFEST, "{editor} exited with {status}; {shown} is as the editor left it");
    }
    let check = if s.global {
        policy::outer().and_then(|o| manifest::parse_with("", false, &o).map(drop))
    } else {
        Manifest::load(&s.config, false).map(drop)
    };
    let g = if s.global { "-g " } else { "" };
    check.map_err(|e| e.hint(format!("your edit is kept in {shown}; fix it with skillcask {g}config edit")))?;
    ui::done("checked", shown);
    Ok(())
}
