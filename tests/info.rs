//! `info`: a package's skills, versions and metadata, and why an installed skill is there.
mod common;

use common::*;
use serde_json::json;

fn md(name: &str, description: &str, requires: &str) -> String {
    format!("---\nname: {name}\ndescription: {description}\n{requires}---\n")
}

/// `acme/multi` with skills `a` and `b`; 1.1.0 is within the cooldown unless `fresh` is false.
fn multi(s: &Server, fresh: bool) {
    let mut list = Vec::new();
    for (v, hours) in [("1.1.0", if fresh { 1 } else { 240 }), ("1.0.0", 240)] {
        let dist = format!("/dist/acme/multi/{v}.zip");
        s.put(
            &dist,
            zipball(&[
                ("skills/a/SKILL.md", &md("a", &format!("does a {v}"), "requires:\n  acme/dep: \"^1.0\"\n")),
                ("skills/b/SKILL.md", &md("b", "does b\u{1b}]0;x", "")),
            ]),
        );
        list.push(json!({ "name": "acme/multi", "version": v, "version_normalized": format!("{v}.0"), "type": "ai-agent-skill",
            "time": ago(hours), "description": "Multi tools\u{1b}]0;x\u{202E}\nfake: line", "license": ["MIT", "Apache-2.0"], "abandoned": "acme/new",
            "dist": { "type": "zip", "url": s.url(&dist) }, "extra": { "ai-agent-skill": ["skills/a", "skills/b"] } }));
    }
    s.put("/p2/acme/multi.json", json!({ "packages": { "acme/multi": list } }).to_string());
    s.put("/packages.json", json!({ "packages": [], "metadata-url": "/p2/%package%.json" }).to_string());
}

fn dep(s: &Server) {
    s.package(
        "acme/dep",
        vec![Ver { version: "1.0.0", time: Some(ago(240)), zip: zipball(&[("SKILL.md", &md("dep", "d", ""))]), extra: None }],
    );
}

#[test]
fn info_shows_skills_versions_and_registry_metadata() {
    let s = Server::start();
    dep(&s);
    multi(&s, true);
    let p = Project::new(&s);
    p.manifest(&s, "");

    let out = p.ok(&["info", "acme/multi"]);
    assert!(out.contains("acme/multi 1.0.0\n"), "newest allowed under the cooldown: {out}");
    assert!(out.contains("description: Multi tools<U+001B>]0;x<U+202E><U+000A>fake: line\n"), "{out}");
    assert!(out.contains("license: MIT, Apache-2.0\n"), "{out}");
    assert!(out.contains("abandoned: use acme/new instead\n"), "{out}");
    assert!(out.contains("versions: 1.1.0, 1.0.0\n"), "{out}");
    assert!(out.contains("requires: acme/dep ^1.0\n"), "{out}");
    assert!(out.contains("  a: does a 1.0.0\n") && out.contains("  b: does b<U+001B>]0;x\n"), "{out}");
    assert!(!out.contains('\u{1b}'), "{out}");
    assert!(!p.exists("skills.lock") && !p.exists(".agents"), "info writes nothing");

    let out = p.ok(&["info", "acme/multi@1.1.0"]);
    assert!(out.contains("acme/multi 1.1.0\n") && out.contains("does a 1.1.0"), "{out}");

    p.ok(&["add", "acme/multi"]);
    multi(&s, false);
    let out = p.ok(&["info", "acme/multi"]);
    assert!(out.contains("acme/multi 1.0.0 (locked)\n"), "the locked version by default: {out}");
    assert!(out.contains("acme/multi: in skills.toml as \"^1.0\"\n"), "{out}");

    // The locked version's skills come from the lock, not from metadata published since.
    let zip = zipball(&[
        ("skills/a/SKILL.md", &md("a", "does a 1.0.0", "requires:\n  acme/dep: \"^1.0\"\n")),
        ("skills/b/SKILL.md", &md("b", "does b\u{1b}]0;x", "")),
    ]);
    s.package("acme/multi", vec![Ver { version: "1.0.0", time: Some(ago(240)), zip, extra: Some(json!(["skills/a"])) }]);
    let out = p.ok(&["info", "acme/multi"]);
    assert!(out.contains("acme/multi 1.0.0 (locked)\n") && out.contains("  b: does b"), "{out}");

    assert!(p.expect(&["info", "acme/multi@9.9.9"], 1).contains("no version of acme/multi matches"));
}

#[test]
fn info_on_a_skill_name_says_which_package_and_entry_install_it() {
    let s = Server::start();
    dep(&s);
    s.package(
        "acme/top",
        vec![Ver {
            version: "1.0.0",
            time: Some(ago(240)),
            zip: zipball(&[("SKILL.md", &md("top", "t", "requires:\n  acme/dep: \"^1.0\"\n"))]),
            extra: None,
        }],
    );
    let p = Project::new(&s);
    p.manifest(&s, "\"acme/top\" = { version = \"^1.0\", rename = { top = \"my-top\" } }\n");
    p.ok(&["install"]);

    let out = p.ok(&["info", "dep"]);
    assert!(out.contains("dep: skill of acme/dep 1.0.0\n"), "{out}");
    assert!(out.contains("acme/dep: required by acme/top (^1.0)\n"), "{out}");
    assert!(out.contains("acme/top: in skills.toml as \"^1.0\"\n"), "{out}");

    let out = p.ok(&["info", "my-top"]);
    assert!(out.contains("my-top: skill top of acme/top 1.0.0, renamed\n"), "{out}");

    p.write(".skills/mine/SKILL.md", &md("mine", "m", ""));
    assert!(p.ok(&["info", "mine"]).contains("mine: project skill in .skills/mine\n"));
    let out = p.expect(&["info", "nope"], 1);
    assert!(out.contains("no installed skill \"nope\""), "{out}");
}

#[test]
fn info_lists_the_skills_of_a_github_repository() {
    let s = Server::start();
    let sha = "a".repeat(40);
    s.put("/repos/acme/tools/tags", "[]");
    s.put("/repos/acme/tools/commits/HEAD", json!({ "sha": sha, "commit": { "committer": { "date": ago(240) } } }).to_string());
    s.put(
        &format!("/repos/acme/tools/zipball/{sha}"),
        zipball(&[("skills/one/SKILL.md", &md("one", "first", "")), ("skills/two/SKILL.md", &md("two", "second", ""))]),
    );
    let mut p = Project::new(&s);
    p.env.push(("SKILLCASK_GITHUB_API".into(), s.base.clone()));
    p.manifest(&s, "");
    let out = p.ok(&["info", "github:acme/tools"]);
    assert!(out.contains(&format!("github:acme/tools {}\n", &sha[..12])), "{out}");
    assert!(out.contains("  one: first\n") && out.contains("  two: second\n"), "{out}");
    let v: serde_json::Value = serde_json::from_slice(&p.run(&["info", "github:acme/tools", "--json"]).stdout).unwrap();
    assert_eq!(v["versions-released"], json!({}), "a ref is not a version");
}

#[test]
fn info_dates_a_locked_tag_without_a_request() {
    let s = Server::start();
    let (c1, c2) = ("1".repeat(40), "2".repeat(40));
    s.put(
        "/repos/acme/tagged/tags",
        json!([{ "name": "v1.1.0", "commit": { "sha": c2 } }, { "name": "v1.0.0", "commit": { "sha": c1 } }]).to_string(),
    );
    let time = ago(240);
    s.put(&format!("/repos/acme/tagged/commits/{c1}"), json!({ "sha": c1, "commit": { "committer": { "date": ago(300) } } }).to_string());
    s.put(&format!("/repos/acme/tagged/commits/{c2}"), json!({ "sha": c2, "commit": { "committer": { "date": time } } }).to_string());
    s.put("/repos/acme/tagged/releases", "[]");
    s.put(&format!("/repos/acme/tagged/zipball/{c2}"), zipball(&[("SKILL.md", &md("tagged", "t", ""))]));
    let mut p = Project::new(&s);
    p.env.push(("SKILLCASK_GITHUB_API".into(), s.base.clone()));
    p.manifest(&s, "");
    p.ok(&["add", "github:acme/tagged"]);
    let commits = || s.log().iter().filter(|l| l.starts_with("/repos/acme/tagged/commits/")).count();
    let before = commits();
    let v: serde_json::Value = serde_json::from_slice(&p.run(&["info", "github:acme/tagged", "--json"]).stdout).unwrap();
    assert_eq!(v["versions"], json!(["v1.1.0", "v1.0.0"]));
    assert_eq!(v["versions-released"], json!({ "v1.1.0": time }), "only the locked tag");
    assert_eq!(commits(), before, "no /commits request: the time is the lock's");
}
