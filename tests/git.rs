//! Plain git source (D30): smart HTTP without a git binary on the client, commit dates as the
//! only times, the lock pinning the commit.
mod common;

use std::path::Path;
use std::process::Command;

use common::*;
use serde_json::json;

/// Commits `files` dated `hours` ago on the current branch, tagged with an annotated `tag`.
fn commit(dir: &Path, files: &[(&str, &str)], hours: i64, tag: Option<&str>) -> String {
    for (path, content) in files {
        let p = dir.join(path);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, content).unwrap();
    }
    let date = format!("@{} +0000", jiff::Timestamp::now().as_second() - hours * 3600);
    let run = |args: &[&str]| {
        let o = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .env("GIT_AUTHOR_DATE", &date)
            .env("GIT_COMMITTER_DATE", &date)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .output()
            .unwrap();
        assert!(o.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&o.stderr));
        String::from_utf8_lossy(&o.stdout).trim().to_string()
    };
    run(&["add", "-A"]);
    for (path, _) in files.iter().filter(|(p, _)| p.ends_with(".sh")) {
        run(&["update-index", "--chmod=+x", path]);
    }
    run(&["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "c"]);
    if let Some(t) = tag {
        run(&["-c", "user.name=t", "-c", "user.email=t@example.com", "tag", "-a", t, "-m", t]);
    }
    run(&["rev-parse", "HEAD"])
}

fn repo() -> tempfile::TempDir {
    let d = tempfile::tempdir().unwrap();
    git(d.path(), &["init", "-q", "-b", "main"]);
    git(d.path(), &["config", "uploadpack.allowFilter", "true"]);
    git(d.path(), &["config", "uploadpack.allowReachableSHA1InWant", "true"]);
    d
}

fn served(s: &Server, dir: &Path) -> String {
    s.serve_git("/acme/skills.git", dir);
    s.url("/acme/skills.git")
}

fn manifest(p: &Project, skills: &str, policy: &str) {
    p.write(
        "skills.toml",
        &format!("[skills]\n{skills}\n[agents]\ntargets = [\".claude/skills\"]\n\n[policy]\npackagist = false\n{policy}"),
    );
}

#[test]
fn tags_install_frozen_and_a_changed_hash_fails() {
    let s = Server::start();
    let r = repo();
    // Two near-identical files make the server send one as a delta of the other.
    let long: String = (0..400).map(|i| format!("line {i} of the reference\n")).collect();
    let old = commit(
        r.path(),
        &[
            ("skills/one/SKILL.md", &skill_md("one")),
            ("skills/one/run.sh", "#!/bin/sh\n"),
            ("skills/one/a.md", &long),
            ("skills/one/b.md", &format!("{long}one more\n")),
        ],
        300,
        Some("v1.0.0"),
    );
    commit(r.path(), &[("skills/one/SKILL.md", &format!("{}new\n", skill_md("one")))], 1, Some("v1.1.0"));
    let url = served(&s, r.path());
    let p = Project::new(&s);
    manifest(&p, "", "");
    p.ok(&["add", &format!("git:{url}")]);
    let lock = p.read("skills.lock");
    assert!(lock.contains("version = \"v1.0.0\"") && lock.contains("type = \"git\"") && lock.contains(&old), "{lock}");
    assert!(
        p.read("skills.toml").contains(&format!("\"acme/skills\" = {{ git = \"{url}\", version = \"^1.0\" }}")),
        "{}",
        p.read("skills.toml")
    );
    assert_eq!(p.read(".agents/skills/one/SKILL.md"), skill_md("one"), "the newer tag is within the cooldown");

    let c = clone_of(&p, &s);
    c.ok(&["install", "--frozen"]);
    assert_eq!(c.read(".agents/skills/one/SKILL.md"), skill_md("one"));
    assert_eq!(c.read(".agents/skills/one/b.md"), format!("{long}one more\n"));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(c.path().join(".agents/skills/one/run.sh")).unwrap().permissions().mode();
        assert!(mode & 0o111 != 0, "exec bit kept");
    }

    let t = clone_of(&p, &s);
    let sha = lock.lines().find_map(|l| l.strip_prefix("dist-sha256 = ")).unwrap().trim_matches('"').to_string();
    t.write("skills.lock", &lock.replace(&sha, &"0".repeat(64)));
    assert!(t.expect(&["install"], 4).contains("expects"));
}

#[test]
fn a_branch_waits_for_its_commit_date() {
    let s = Server::start();
    let r = repo();
    let old = commit(r.path(), &[("SKILL.md", &skill_md("tool"))], 300, None);
    let new = commit(r.path(), &[("SKILL.md", &format!("{}fresh\n", skill_md("tool")))], 1, None);
    let url = served(&s, r.path());
    let p = Project::new(&s);
    manifest(&p, "", "");
    let out = p.ok(&["add", &format!("git:{url}")]);
    assert!(out.contains("newer commits on \"HEAD\""), "{out}");
    let lock = p.read("skills.lock");
    assert!(lock.contains(&old) && !lock.contains(&new), "{lock}");

    // A commit is never trusted to be older than it says, only younger.
    let q = Project::new(&s);
    manifest(&q, &format!("\"acme/skills\" = {{ git = \"{url}\", ref = \"{new}\" }}\n"), "");
    assert!(q.expect(&["install"], 1).contains("newer than policy.min-release-age"));
}

#[test]
fn allow_sources_applies_by_url_prefix_and_drift_fails_frozen() {
    let s = Server::start();
    let r = repo();
    commit(r.path(), &[("SKILL.md", &skill_md("tool"))], 300, Some("v1.0.0"));
    let url = served(&s, r.path());
    let p = Project::new(&s);
    manifest(&p, "", "allow-sources = [\"https://git.example.com/\"]\n");
    let out = p.expect(&["add", &format!("git:{url}")], 1);
    assert!(out.contains("not in policy.allow-sources"), "{out}");
    assert!(!p.exists("skills.lock"));

    manifest(&p, "", &format!("allow-sources = [\"{}\"]\n", s.url("/acme/")));
    p.ok(&["add", &format!("git:{url}")]);

    let mut c = clone_of(&p, &s);
    manifest(
        &c,
        &format!("\"acme/skills\" = {{ git = \"{url}\", version = \"^1.0\" }}\n\"acme/other\" = {{ git = \"{url}\", ref = \"main\" }}\n"),
        "",
    );
    c.env.push(("CI".into(), "true".into()));
    assert!(c.expect(&["install"], 1).contains("acme/other"));
    assert!(!c.exists(".agents/skills/tool"), "nothing installed under --frozen");
}

#[test]
fn dot_segments_do_not_escape_an_enforced_prefix() {
    let s = Server::start();
    let r = repo();
    commit(r.path(), &[("SKILL.md", &skill_md("tool"))], 300, Some("v1.0.0"));
    served(&s, r.path());
    let p = Project::new(&s);
    p.config(&format!("[policy]\nallow-sources = [\"{}\"]\nenforce = [\"allow-sources\"]\n", s.url("/trusted/")));
    manifest(&p, "", "");
    // The request would go to /acme/skills.git, outside the prefix the string starts with.
    let out = p.expect(&["add", &format!("git:{}", s.url("/trusted/../acme/skills.git"))], 1);
    assert!(out.contains("not in policy.allow-sources"), "{out}");
    assert!(s.log().is_empty(), "{:?}", s.log());
    assert!(!p.exists("skills.lock"));
}

#[test]
fn credentials_come_from_auth_json() {
    let s = Server::start();
    let r = repo();
    commit(r.path(), &[("SKILL.md", &skill_md("tool"))], 300, Some("v1.0.0"));
    let url = served(&s, r.path());
    s.require_auth(Some("Bearer t0ken"));
    let p = Project::new(&s);
    manifest(&p, "", "");
    assert_eq!(p.run(&["add", &format!("git:{url}")]).status.code(), Some(2));
    let host = s.base.trim_start_matches("https://").to_string();
    p.write("auth.json", &json!({ "bearer": { host: "t0ken" } }).to_string());
    p.ok(&["add", &format!("git:{url}")]);
    assert!(s.requests().iter().any(|r| r.path.ends_with("/git-upload-pack")));
}

#[test]
fn github_token_goes_to_a_git_host_only_when_the_user_names_it() {
    let s = Server::start();
    let r = repo();
    commit(r.path(), &[("SKILL.md", &skill_md("tool"))], 300, Some("v1.0.0"));
    let url = served(&s, r.path());
    let mut p = Project::new(&s);
    p.env.push(("GITHUB_TOKEN".into(), "ght0ken".into()));
    // The project names the git host as its GitHub API; that does not make it trusted.
    p.write(
        "skills.toml",
        &format!(
            "[repositories]\npackagist = false\ngithub = {{ type = \"github\", url = \"{}\" }}\n\n[agents]\ntargets = [\".claude/skills\"]\n",
            s.url("/api")
        ),
    );
    p.ok(&["add", &format!("git:{url}")]);
    assert!(!s.log().is_empty() && s.log().iter().all(|l| l.ends_with("auth=false")), "{:?}", s.log());

    // The user names it (GitHub Enterprise): the token goes along.
    std::fs::remove_file(p.path().join("skills.lock")).unwrap();
    p.env.push(("SKILLCASK_GITHUB_API".into(), s.url("/api")));
    p.ok(&["update"]);
    assert!(s.log().iter().any(|l| l.ends_with("auth=true")), "{:?}", s.log());
}

#[test]
fn requires_and_info_take_a_git_target() {
    let s = Server::start();
    let r = repo();
    commit(r.path(), &[("skills/one/SKILL.md", &skill_md("one")), ("skills/two/SKILL.md", &skill_md("two"))], 300, Some("v1.2.0"));
    let url = served(&s, r.path());
    let md = format!("---\nname: foo\ndescription: d\nrequires:\n  \"git:{url}#one\": \"^1\"\n---\n# foo\n");
    let zip = zipball(&[("SKILL.md", &md)]);
    s.package("acme/x", vec![Ver { version: "1.0.0", time: Some(ago(240)), zip, extra: None }]);
    let p = Project::new(&s);
    let composer = format!("[repositories]\nfix = {{ type = \"composer\", url = \"{}\" }}\n\n", s.url("/packages.json"));
    p.write("skills.toml", &format!("{composer}[skills]\n\n[policy]\npackagist = false\n"));
    assert!(p.expect(&["add", "acme/x"], 1).contains("a git source; allow GitHub and git dependencies with `github-requires = true`"));

    p.write("skills.toml", &format!("{composer}[skills]\n\n[policy]\npackagist = false\ngithub-requires = true\n"));
    let out = p.ok(&["add", "acme/x"]);
    assert!(out.contains("added acme/skills v1.2.0 (dependency of acme/x)"), "{out}");
    assert!(p.exists(".agents/skills/one") && !p.exists(".agents/skills/two"), "only the required skill");
    let lock = p.read("skills.lock");
    assert!(lock.contains(&format!("url = \"{url}\"")) && lock.contains("type = \"git\""), "{lock}");
    assert!(clone_of(&p, &s).ok(&["install", "--frozen"]).contains("one"));

    let q = Project::new(&s);
    q.write("skills.toml", "[skills]\n\n[policy]\npackagist = false\n");
    let out = q.ok(&["info", &format!("git:{url}")]);
    assert!(out.contains("acme/skills") && out.contains("1.2.0") && out.contains("two"), "{out}");
    let v: serde_json::Value = serde_json::from_slice(&q.run(&["info", &format!("git:{url}@^1"), "--json"]).stdout).unwrap();
    assert_eq!((v["source"].as_str(), v["version"].as_str()), (Some("git"), Some("v1.2.0")));
    let dated: Vec<&String> = v["versions-released"].as_object().unwrap().keys().collect();
    assert_eq!(dated, ["v1.2.0"], "only the resolved tag: {v}");
    assert!(v["versions-released"]["v1.2.0"].as_str().unwrap().parse::<jiff::Timestamp>().is_ok(), "{v}");
    assert!(q.expect(&["info", "git:http://example.com/a/b.git"], 1).contains("must start with https://"));
}

#[test]
fn a_moved_tag_is_reported() {
    let s = Server::start();
    let r = repo();
    commit(r.path(), &[("skills/one/SKILL.md", &skill_md("one"))], 300, Some("v1.0.0"));
    let url = served(&s, r.path());
    let p = Project::new(&s);
    manifest(&p, &format!("\"acme/skills\" = {{ git = \"{url}\", version = \"^1.0\" }}\n"), "");
    p.ok(&["install"]);
    assert!(!p.ok(&["outdated"]).contains("moved"));

    commit(r.path(), &[("skills/one/SKILL.md", &format!("{}changed\n", skill_md("one")))], 200, None);
    git(r.path(), &["-c", "user.name=t", "-c", "user.email=t@example.com", "tag", "-f", "-a", "v1.0.0", "-m", "again"]);
    let out = p.ok(&["outdated"]);
    assert!(out.contains("warning: acme/skills: tag v1.0.0 moved from "), "{out}");
    let v: serde_json::Value = serde_json::from_slice(&p.run(&["outdated", "--json"]).stdout).unwrap();
    let row = &v["packages"][0];
    assert!(row["note"].as_str().unwrap().starts_with("tag v1.0.0 moved from "), "{v}");
    assert!(row["locked-released"].as_str().unwrap().parse::<jiff::Timestamp>().is_ok(), "{v}");
    let undated = [&row["within-released"], &row["latest-released"], &row["eligible"]];
    assert_eq!(undated, [&serde_json::Value::Null; 3], "{v}");
    let out = p.ok(&["update"]);
    assert!(out.contains("acme/skills v1.0.0: same version, other content (a moved tag or a republished version)"), "{out}");
}

#[test]
fn a_repository_min_release_age_exception_covers_git_entries() {
    let s = Server::start();
    let r = repo();
    let fresh = commit(r.path(), &[("SKILL.md", &skill_md("tool"))], 1, None);
    let url = served(&s, r.path());
    s.serve_git("/other/skills.git", r.path());
    let other = s.url("/other/skills.git");
    let p = Project::new(&s);
    manifest(&p, "", "");
    p.config(&format!(
        "[policy]\nmin-release-age = \"3d\"\nenforce = [\"min-release-age\"]\n\n[policy.repository-min-release-age]\n\"{}\" = \"0\"\n",
        s.url("/acme/")
    ));
    p.ok(&["add", &format!("git:{url}")]);
    assert!(p.read("skills.lock").contains(&fresh), "{}", p.read("skills.lock"));
    p.ok(&["install", "--frozen"]);

    // The same commit under a prefix without the exception keeps the enforced cooldown.
    assert!(p.expect(&["add", &format!("git:{other}")], 1).contains("newer than policy.min-release-age (3d"));
    p.write("skills.lock", &p.read("skills.lock").replace(&url, &other));
    p.write("skills.toml", &p.read("skills.toml").replace(&url, &other));
    assert!(p.expect(&["install", "--frozen"], 1).contains("newer than policy.min-release-age (3d, config.toml, enforced)"));
}
