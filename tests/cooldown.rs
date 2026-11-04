//! `min-release-age` per repository.
mod common;

use common::*;
use serde_json::json;

#[test]
fn a_repository_can_set_its_own_min_release_age() {
    let s = Server::start();
    let z = || zipball(&[("SKILL.md", &skill_md("one"))]);
    s.package(
        "acme/one",
        vec![
            Ver { version: "1.1.0", time: Some(ago(1)), zip: z(), extra: None },
            Ver { version: "1.0.0", time: Some(ago(240)), zip: z(), extra: None },
        ],
    );
    let dist = "/pub/acme/two/2.0.0.zip";
    s.put(dist, zipball(&[("SKILL.md", &skill_md("two"))]));
    s.put(
        "/pub/packages.json",
        json!({ "packages": { "acme/two": { "2.0.0": {
            "name": "acme/two", "version": "2.0.0", "version_normalized": "2.0.0.0", "type": "ai-agent-skill",
            "time": ago(1), "dist": { "type": "zip", "url": s.url(dist) },
        } } } })
        .to_string(),
    );
    let p = Project::new(&s);
    p.write(
        "skills.toml",
        &format!(
            "[repositories]\ninternal = {{ url = \"{}\", min-release-age = \"0\" }}\npub = {{ url = \"{}\" }}\n[policy]\npackagist = false\n",
            s.url("/packages.json"),
            s.url("/pub/packages.json")
        ),
    );
    p.ok(&["add", "acme/one"]);
    assert!(p.read("skills.lock").contains("version = \"1.1.0\""), "{}", p.read("skills.lock"));
    assert!(p.expect(&["add", "acme/two"], 1).contains("newer than policy.min-release-age"));

    p.write("skills.toml", &p.read("skills.toml").replace("min-release-age = \"0\"", "min-release-age = 3"));
    assert!(p.expect(&["install"], 1).contains("repository internal: min-release-age must be a string"));
}

fn young_and_old(s: &Server) {
    let z = || zipball(&[("SKILL.md", &skill_md("one"))]);
    s.package(
        "acme/one",
        vec![
            Ver { version: "1.1.0", time: Some(ago(1)), zip: z(), extra: None },
            Ver { version: "1.0.0", time: Some(ago(240)), zip: z(), extra: None },
        ],
    );
}

#[test]
fn a_cooldown_the_project_cannot_change_also_holds_the_lock() {
    let s = Server::start();
    young_and_old(&s);
    let mut p = Project::new(&s);
    p.manifest(&s, "");
    p.env.push(("SKILLCASK_MIN_RELEASE_AGE".into(), "0".into()));
    p.ok(&["add", "acme/one"]);
    assert!(p.read("skills.lock").contains("version = \"1.1.0\""), "{}", p.read("skills.lock"));
    p.env.retain(|(k, _)| k != "SKILLCASK_MIN_RELEASE_AGE");

    // The project's own cooldown does not reach a version it already locked (D7).
    p.write("skills.toml", &p.read("skills.toml").replace("[policy]\n", "[policy]\nmin-release-age = \"3d\"\n"));
    p.ok(&["install", "--frozen"]);

    p.env.push(("SKILLCASK_MIN_RELEASE_AGE".into(), "3d".into()));
    let e = p.expect(&["install", "--frozen"], 1);
    assert!(e.contains("acme/one 1.1.0 was released") && e.contains("newer than policy.min-release-age (72h, environment)"), "{e}");
    assert!(e.contains("hint: it becomes eligible at"), "{e}");
    p.env.retain(|(k, _)| k != "SKILLCASK_MIN_RELEASE_AGE");

    p.write("skills.toml", &p.read("skills.toml").replace("min-release-age = \"3d\"\n", ""));
    p.config("[policy]\nmin-release-age = \"3d\"\nenforce = [\"min-release-age\"]\n");
    let e = p.expect(&["install", "--frozen"], 1);
    assert!(e.contains("newer than policy.min-release-age (72h, config.toml, enforced)"), "{e}");
    // An exception for the repository lets it through, as at resolution (D28).
    p.config(&format!(
        "[policy]\nmin-release-age = \"3d\"\nenforce = [\"min-release-age\"]\n\n[policy.repository-min-release-age]\n\"{}\" = \"0\"\n",
        s.url("/")
    ));
    p.ok(&["install", "--frozen"]);
}

#[test]
fn the_environment_cannot_shorten_an_enforced_cooldown_or_its_repository_floor() {
    let s = Server::start();
    young_and_old(&s);
    let mut p = Project::new(&s);
    p.write(
        "skills.toml",
        &format!(
            "[repositories]\ninternal = {{ url = \"{}\", min-release-age = \"0\" }}\n[policy]\npackagist = false\n",
            s.url("/packages.json")
        ),
    );
    p.config("[policy]\nmin-release-age = \"3d\"\nenforce = [\"min-release-age\"]\n");
    assert!(p.expect(&["add", "acme/one"], 1).contains("is shorter than \"72h\""));
    p.env.push(("SKILLCASK_MIN_RELEASE_AGE".into(), "3d".into()));
    assert!(p.expect(&["add", "acme/one"], 1).contains("is shorter than \"72h\""), "the same value lifts nothing");
    // A shorter value cannot lift it (D18); a longer one raises the floor with it.
    p.env.retain(|(k, _)| k != "SKILLCASK_MIN_RELEASE_AGE");
    p.env.push(("SKILLCASK_MIN_RELEASE_AGE".into(), "1h".into()));
    assert!(p.expect(&["add", "acme/one"], 1).contains("SKILLCASK_MIN_RELEASE_AGE = \"1h\" loosens policy.min-release-age"));
    p.env.retain(|(k, _)| k != "SKILLCASK_MIN_RELEASE_AGE");
    p.env.push(("SKILLCASK_MIN_RELEASE_AGE".into(), "7d".into()));
    assert!(p.expect(&["add", "acme/one"], 1).contains("is shorter than \"168h\""));
}

#[test]
fn a_bad_cooldown_in_config_toml_names_only_that_file() {
    let s = Server::start();
    let p = Project::new(&s);
    p.manifest(&s, "");
    p.config("[policy]\nmin-release-age = \"bogus\"\n");
    let e = p.expect(&["status"], 1);
    assert!(e.contains("config.toml: policy.min-release-age invalid duration \"bogus\""), "{e}");
    assert!(!e.contains("skills.toml"), "{e}");
}
