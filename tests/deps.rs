//! Dependencies between skills: `requires:` in SKILL.md (D16).
mod common;

use common::*;
use serde_json::json;

fn md(name: &str, requires: &[(&str, &str)]) -> String {
    let lines: String = requires.iter().map(|(k, v)| format!("  {k}: \"{v}\"\n")).collect();
    format!("---\nname: {name}\ndescription: test skill {name}\nrequires:\n{lines}---\n# {name}\n")
}

/// `name` with one root skill per version, released 10 days ago, newest first.
fn package(s: &Server, name: &str, versions: &[(&str, &[(&str, &str)])]) {
    let skill = name.split('/').nth(1).unwrap();
    let vs = versions
        .iter()
        .map(|(v, req)| Ver { version: v, time: Some(ago(240)), zip: zipball(&[("SKILL.md", &md(skill, req))]), extra: None })
        .collect();
    s.package(name, vs);
}

fn project(s: &Server, policy: &str) -> Project {
    let p = Project::new(s);
    p.write(
        "skills.toml",
        &format!("[repositories]\nfix = {{ url = \"{}\" }}\n[policy]\npackagist = false\n{policy}\n", s.url("/packages.json")),
    );
    p
}

fn mr(s: &Server) {
    package(s, "acme/mr", &[("1.0.0", &[("acme/ssdlc", "^1.0"), ("acme/pr", "^1.0")])]);
    package(s, "acme/ssdlc", &[("1.1.0", &[]), ("1.0.0", &[])]);
    package(s, "acme/pr", &[("1.0.0", &[])]);
}

#[test]
fn add_locks_and_installs_dependencies_and_a_frozen_clone_reproduces_them() {
    let s = Server::start();
    mr(&s);
    let p = project(&s, "");
    let out = p.ok(&["add", "acme/mr"]);
    assert!(out.contains("added acme/ssdlc 1.1.0 (dependency of acme/mr)") && out.contains("added acme/pr 1.0.0"), "{out}");
    let lock = p.read("skills.lock");
    assert!(lock.contains("version = 2\n"), "{lock}");
    assert!(lock.contains("requires = { \"acme/pr\" = \"^1.0\", \"acme/ssdlc\" = \"^1.0\" }"), "{lock}");
    assert!(!p.read("skills.toml").contains("ssdlc"), "dependencies stay out of the manifest");
    for n in ["mr", "ssdlc", "pr"] {
        assert!(p.exists(&format!(".agents/skills/{n}/SKILL.md")) && p.exists(&format!(".claude/skills/{n}")), "{n}");
    }
    let st = p.ok(&["status"]);
    assert!(st.lines().any(|l| l.starts_with("acme/ssdlc ") && l.ends_with(" via acme/mr")), "{st}");
    // Regression: the JSON `package` held the text label, and the apps passed it on as a name.
    let js: serde_json::Value = serde_json::from_str(&p.ok(&["status", "--json"])).unwrap();
    let dep = js["entries"].as_array().unwrap().iter().find(|e| e["skill"] == "ssdlc").unwrap();
    assert_eq!((&dep["package"], &dep["via"]), (&serde_json::json!("acme/ssdlc"), &serde_json::json!(["acme/mr"])), "{js}");
    assert!(dep["released"].as_str().is_some_and(|t| t.parse::<jiff::Timestamp>().is_ok()), "{js}");

    let mut c = clone_of(&p, &s);
    c.env.push(("CI".into(), "true".into()));
    c.ok(&["install"]);
    assert_eq!(c.read(".agents/skills/ssdlc/SKILL.md"), p.read(".agents/skills/ssdlc/SKILL.md"));
    assert_eq!(c.read("skills.lock"), lock);

    // A lock edited to drop a dependency is drift under --frozen.
    let start = lock.find("\n[[package]]\nname = \"acme/pr\"").unwrap();
    let end = lock[start + 1..].find("\n[[package]]").map_or(lock.len(), |n| start + 1 + n);
    c.write("skills.lock", &format!("{}{}", &lock[..start], &lock[end..]));
    let e = c.expect(&["install"], 1);
    assert!(e.contains("acme/pr: not in skills.lock"), "{e}");
}

/// Regression guard: `requires` in the lock is not covered by a hash, so it must match the
/// requirer's SKILL.md. Otherwise a lock-only change could add a package that skills.toml never
/// asked for and `install --frozen` would accept it.
#[test]
fn lock_requires_must_match_the_skill() {
    let s = Server::start();
    package(&s, "acme/mr", &[("1.0.0", &[])]);
    package(&s, "acme/evil", &[("1.0.0", &[])]);
    let p = project(&s, "");
    p.ok(&["add", "acme/mr"]);
    let other = project(&s, "");
    other.ok(&["add", "acme/evil"]);
    let evil = other.read("skills.lock");
    let evil = &evil[evil.find("\n[[package]]").unwrap()..];
    let forged = p
        .read("skills.lock")
        .replace("version = 1\n", "version = 2\n")
        .replace("dist-sha256", "requires = { \"acme/evil\" = \"^1.0\" }\ndist-sha256")
        + evil;
    let mut c = clone_of(&p, &s);
    c.write("skills.lock", &forged);
    c.env.push(("CI".into(), "true".into()));
    let e = c.expect(&["install"], 4);
    assert!(e.contains("acme/mr") && e.contains("requires"), "{e}");
    assert!(!c.exists(".agents/skills/evil"));
}

#[test]
fn requirers_share_one_version_or_fail_naming_each_other() {
    let s = Server::start();
    package(&s, "acme/a", &[("1.0.0", &[("acme/c", "^1.1")])]);
    package(&s, "acme/b", &[("1.0.0", &[("acme/c", "^1.0")])]);
    package(&s, "acme/z", &[("1.0.0", &[("acme/c", "^2.0")])]);
    package(&s, "acme/c", &[("2.0.0", &[]), ("1.2.0", &[]), ("1.0.0", &[])]);
    let p = project(&s, "");
    p.ok(&["add", "acme/a"]);
    p.ok(&["add", "acme/b"]);
    let lock = p.read("skills.lock");
    assert!(lock.contains("name = \"acme/c\"\nconstraint = \"^1.0, ^1.1\"\nversion = \"1.2.0\""), "{lock}");

    let toml = p.read("skills.toml");
    let e = p.expect(&["add", "acme/z"], 1);
    assert!(e.contains("acme/c") && e.contains("required by: acme/a (^1.1), acme/b (^1.0), acme/z (^2.0)"), "{e}");
    assert_eq!(p.read("skills.lock"), lock, "nothing written");
    assert_eq!(p.read("skills.toml"), toml);
}

#[test]
fn a_dependency_comes_only_from_declared_repositories() {
    let s = Server::start();
    package(&s, "acme/mr", &[("1.0.0", &[("acme/elsewhere", "^1.0")])]);
    let p = project(&s, "");
    let e = p.expect(&["add", "acme/mr"], 1);
    assert!(e.contains("acme/elsewhere") && e.contains("required by: acme/mr"), "{e}");
    assert!(!p.exists("skills.lock") && !p.read("skills.toml").contains("acme/mr"));
}

#[test]
fn github_dependencies_need_the_opt_in_and_install_the_named_skill() {
    let s = Server::start();
    package(&s, "acme/mr", &[("1.0.0", &[("github:mattpocock/skills/pr", "main")])]);
    let sha = "2".repeat(40);
    s.put("/repos/mattpocock/skills/commits/main", json!({ "sha": sha, "commit": { "committer": { "date": ago(240) } } }).to_string());
    s.put(
        &format!("/repos/mattpocock/skills/zipball/{sha}"),
        zipball(&[("skills/pr/SKILL.md", &skill_md("pr")), ("skills/tdd/SKILL.md", &skill_md("tdd"))]),
    );
    let mut p = project(&s, "");
    p.env.push(("SKILLCASK_GITHUB_API".into(), s.base.clone()));
    let e = p.expect(&["add", "acme/mr"], 1);
    assert!(e.contains("github-requires = true"), "{e}");

    p.write("skills.toml", &p.read("skills.toml").replace("packagist = false", "packagist = false\ngithub-requires = true"));
    p.ok(&["add", "acme/mr"]);
    assert!(p.exists(".agents/skills/pr/SKILL.md") && !p.exists(".agents/skills/tdd"));
    let lock = p.read("skills.lock");
    assert!(lock.contains("name = \"mattpocock/skills\"\nconstraint = \"main\"\nref = true"), "{lock}");
    assert!(lock.contains("selected = [\"pr\"]"), "{lock}");
}

#[test]
fn remove_drops_orphans_and_keeps_shared_dependencies() {
    let s = Server::start();
    mr(&s);
    package(&s, "acme/review", &[("1.0.0", &[("acme/ssdlc", "^1.0")])]);
    let p = project(&s, "");
    p.ok(&["add", "acme/mr"]);
    p.ok(&["add", "acme/review"]);
    let e = p.expect(&["remove", "acme/ssdlc"], 1);
    assert!(e.contains("acme/ssdlc is a dependency") && e.contains("acme/mr") && e.contains("acme/review"), "{e}");

    p.ok(&["remove", "acme/mr"]);
    let lock = p.read("skills.lock");
    assert!(!lock.contains("acme/pr") && lock.contains("name = \"acme/ssdlc\""), "{lock}");
    assert!(!p.exists(".agents/skills/pr") && p.exists(".agents/skills/ssdlc"));

    p.ok(&["remove", "acme/review"]);
    assert!(!p.read("skills.lock").contains("acme/ssdlc"));
    assert!(!p.exists(".agents/skills/ssdlc"));
}

#[test]
fn a_manifest_entry_that_is_also_required_is_kept_on_remove() {
    let s = Server::start();
    mr(&s);
    let p = project(&s, "");
    p.ok(&["add", "acme/ssdlc"]);
    p.ok(&["add", "acme/mr"]);
    let out = p.ok(&["remove", "acme/ssdlc"]);
    assert!(out.contains("kept acme/ssdlc as a dependency"), "{out}");
    assert!(!p.read("skills.toml").contains("acme/ssdlc") && p.exists(".agents/skills/ssdlc"));
    p.ok(&["status"]);
}

#[test]
fn requires_of_unselected_skills_are_ignored() {
    let s = Server::start();
    let zip = zipball(&[("alpha/SKILL.md", &md("alpha", &[("acme/missing", "^1")])), ("beta/SKILL.md", &skill_md("beta"))]);
    s.package("acme/multi", vec![Ver { version: "1.0.0", time: Some(ago(240)), zip, extra: Some(json!(["alpha", "beta"])) }]);
    let p = project(&s, "");
    p.write(
        "skills.toml",
        &p.read("skills.toml").replace("[policy]", "[skills]\n\"acme/multi\" = { version = \"^1.0\", skills = [\"beta\"] }\n[policy]"),
    );
    p.ok(&["install"]);
    assert!(!p.read("skills.lock").contains("requires"));
}

#[test]
fn a_cycle_installs_both() {
    let s = Server::start();
    package(&s, "acme/a", &[("1.0.0", &[("acme/b", "^1.0")])]);
    package(&s, "acme/b", &[("1.0.0", &[("acme/a", "^1.0")])]);
    let p = project(&s, "");
    p.ok(&["add", "acme/a"]);
    assert!(p.exists(".agents/skills/a") && p.exists(".agents/skills/b"));
    p.ok(&["status"]);
    let again = p.ok(&["install"]);
    assert!(!again.contains("installed"), "{again}");
}

#[test]
fn update_brings_in_what_a_new_version_requires() {
    let s = Server::start();
    package(&s, "acme/mr", &[("1.0.0", &[])]);
    let p = project(&s, "");
    p.ok(&["add", "acme/mr"]);
    assert!(p.read("skills.lock").contains("version = 1\n"));
    package(&s, "acme/mr", &[("1.1.0", &[("acme/pr", "^1.0")]), ("1.0.0", &[])]);
    package(&s, "acme/pr", &[("1.0.0", &[])]);
    let out = p.ok(&["update"]);
    assert!(out.contains("updated acme/mr 1.0.0 -> 1.1.0") && out.contains("added acme/pr 1.0.0 (dependency of acme/mr)"), "{out}");
    assert!(p.exists(".agents/skills/pr"));
}
