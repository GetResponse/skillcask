//! `self-check` (D51): the tap's cask file decides whether a newer skillcask is released.
mod common;

use common::*;
use serde_json::{Value, json};

const CASK: &str = "/Casks/skillcask-app.rb";
const RUNNING: &str = env!("CARGO_PKG_VERSION");

fn cask(version: &str) -> String {
    format!(
        "cask \"skillcask-app\" do\n  version \"{version}\"\n  sha256 \"0000\"\n\n  url \"https://github.com/GetResponse/skillcask/releases/download/v#{{version}}/Skillcask-#{{version}}-macos-universal.zip\"\n  name \"Skillcask\"\n\n  app \"Skillcask.app\"\nend\n"
    )
}

fn project(s: &Server) -> Project {
    let mut p = Project::new(s);
    p.env.push(("SKILLCASK_SELF_CHECK_URL".into(), s.url(CASK)));
    p
}

fn json_of(out: &str) -> Value {
    let line = out.lines().find(|l| l.starts_with('{')).unwrap_or_else(|| panic!("no JSON: {out}"));
    serde_json::from_str(line).unwrap()
}

#[test]
fn reports_a_newer_release() {
    let s = Server::start();
    s.put(CASK, cask("999.0.0"));
    let p = project(&s);
    let out = p.ok(&["self-check"]);
    assert!(out.contains(&format!("skillcask {RUNNING}, latest 999.0.0: update available")), "{out}");
    assert!(out.contains("https://github.com/GetResponse/skillcask/releases/tag/v999.0.0"), "{out}");
    let o = p.run(&["self-check", "--json"]);
    assert_eq!(o.status.code(), Some(0));
    let stdout = String::from_utf8(o.stdout).unwrap();
    assert_eq!(stdout.lines().count(), 1, "one compact line: {stdout}");
    assert_eq!(serde_json::from_str::<Value>(&stdout).unwrap(), json!({ "version": RUNNING, "latest": "999.0.0", "newer": true }));
}

#[test]
fn same_or_older_is_up_to_date() {
    let s = Server::start();
    s.put(CASK, cask(RUNNING));
    let p = project(&s);
    let out = p.ok(&["self-check"]);
    assert!(out.contains(&format!("skillcask {RUNNING}, latest {RUNNING}: up to date")), "{out}");
    assert_eq!(json_of(&p.ok(&["self-check", "--json"])), json!({ "version": RUNNING, "latest": RUNNING, "newer": false }));

    s.put(CASK, cask("0.0.1"));
    assert!(p.ok(&["self-check"]).contains("latest 0.0.1: up to date"));
    assert_eq!(json_of(&p.ok(&["self-check", "--json"]))["newer"], json!(false));
    // A pre-release of the running version comes before it.
    s.put(CASK, cask(&format!("{RUNNING}-rc.1")));
    assert_eq!(json_of(&p.ok(&["self-check", "--json"]))["newer"], json!(false));
}

#[test]
fn an_unreadable_version_is_unknown_not_an_error() {
    let s = Server::start();
    let p = project(&s);
    for body in [cask("latest\" # \"1.0"), cask("v999.0.0"), "<html>oops</html>".into(), String::new()] {
        s.put(CASK, body);
        let out = p.ok(&["self-check"]);
        assert!(out.contains(&format!("skillcask {RUNNING}, latest unknown")) && out.contains("warning:"), "{out}");
        let o = p.run(&["self-check", "--json"]);
        assert_eq!(o.status.code(), Some(0));
        let doc: Value = serde_json::from_slice(&o.stdout).unwrap();
        assert_eq!(doc, json!({ "version": RUNNING, "latest": null, "newer": false }));
    }
}

#[test]
fn http_errors_exit_3_with_a_hint() {
    let s = Server::start();
    let p = project(&s);
    let out = p.expect(&["self-check"], 3);
    assert!(out.contains("skillcask-app.rb: not found") && out.contains("hint:"), "{out}");
    s.respond(CASK, 503, &[("Retry-After", "0")], "");
    let out = p.expect(&["self-check", "--json"], 3);
    assert!(out.contains("HTTP 503") && out.contains("hint: check the connection") && !out.contains('{'), "{out}");
    s.respond(CASK, 403, &[], "");
    let out = p.expect(&["self-check"], 3);
    assert!(out.contains("HTTP 403") && out.contains("hint: check the connection") && !out.contains("auth.json"), "{out}");
    let mut p = p;
    p.env.push(("SKILLCASK_SELF_CHECK_URL".into(), s.url(CASK).replace("https:", "http:")));
    let out = p.expect(&["self-check"], 3);
    assert!(out.contains("refusing non-HTTPS URL") && out.contains("hint: SKILLCASK_SELF_CHECK_URL must be an https:// URL"), "{out}");
    assert!(!out.contains("check the connection") && s.requests().iter().all(|r| r.path == CASK), "{out}");
}

#[test]
fn the_body_is_capped_at_64_kib() {
    let s = Server::start();
    let p = project(&s);
    let mut body = cask("999.0.0");
    body.push_str(&"#".repeat(64 * 1024 - body.len()));
    s.put(CASK, body.clone());
    assert_eq!(json_of(&p.ok(&["self-check", "--json"]))["latest"], json!("999.0.0"));
    body.push('#');
    s.put(CASK, body);
    let out = p.expect(&["self-check"], 3);
    assert!(out.contains("exceeds the limit of 65536 bytes"), "{out}");
}

#[test]
fn sends_no_credential_even_after_a_redirect() {
    let s = Server::start();
    s.put(CASK, cask("999.0.0"));
    s.redirect("/moved", CASK);
    let host = s.base.trim_start_matches("https://").to_string();
    let mut p = Project::new(&s);
    // Every source that would give this host a token: GITHUB_TOKEN for the API named here
    // (D43), COMPOSER_AUTH, auth.json, git's credential helper and userinfo in the URL.
    p.env.push(("SKILLCASK_SELF_CHECK_URL".into(), format!("https://user:pass@{host}/moved")));
    p.env.push(("SKILLCASK_GITHUB_API".into(), s.base.clone()));
    p.env.push(("GITHUB_TOKEN".into(), "ghp_secret".into()));
    p.env.push(("GH_TOKEN".into(), "ghp_secret".into()));
    p.env.push(("COMPOSER_AUTH".into(), format!(r#"{{"bearer":{{"{host}":"composer"}}}}"#)));
    std::fs::write(p.home().join("auth.json"), format!(r#"{{"http-basic":{{"{host}":{{"username":"u","password":"p"}}}}}}"#)).unwrap();
    let helper = "!f() { [ \"$1\" = get ] && printf 'username=oauth2\\npassword=helper\\n'; }; f";
    std::fs::write(p.home().join(".gitconfig"), format!("[credential]\n\thelper = {helper:?}\n")).unwrap();
    let out = p.ok(&["self-check", "-v"]);
    assert!(out.contains("update available") && !out.contains("pass@"), "{out}");
    let reqs = s.requests();
    assert_eq!(reqs.iter().map(|r| r.path.as_str()).collect::<Vec<_>>(), ["/moved", CASK]);
    for r in reqs {
        assert!(!r.headers.contains_key("authorization") && !r.headers.contains_key("private-token"), "{:?}", r.headers);
        assert!(r.headers.get("user-agent").is_some_and(|ua| ua.starts_with("skillcask/")), "{:?}", r.headers);
    }
}

#[test]
fn works_anywhere_and_writes_nothing() {
    let s = Server::start();
    s.put(CASK, cask("999.0.0"));
    let mut p = project(&s);
    let empty = tempfile::tempdir().unwrap();
    p.cwd = Some(empty.path().to_path_buf());
    p.ok(&["self-check"]);
    p.ok(&["-g", "self-check", "--json"]);
    assert_eq!(std::fs::read_dir(empty.path()).unwrap().count(), 0);
    assert_eq!(std::fs::read_dir(p.home()).unwrap().count(), 0, "no cache or config in the home directory");
}

#[test]
#[ignore]
fn live_cask_has_a_version() {
    let o = std::process::Command::new(env!("CARGO_BIN_EXE_skillcask"))
        .args(["self-check", "--json"])
        .env_remove("CI")
        .env_remove("SKILLCASK_SELF_CHECK_URL")
        .output()
        .unwrap();
    assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
    let doc: Value = serde_json::from_slice(&o.stdout).unwrap();
    assert_eq!(doc["version"], json!(RUNNING));
    assert!(doc["latest"].is_string(), "{doc}");
}
