mod common;

use common::*;
use serde_json::json;

fn gh_commit(sha: &str, hours: i64) -> serde_json::Value {
    json!({ "sha": sha, "commit": { "committer": { "date": ago(hours) } } })
}

fn with_github(mut p: Project, s: &Server) -> Project {
    p.env.push(("SKILLCASK_GITHUB_API".into(), s.base.clone()));
    p
}

#[test]
fn duplicate_tags_keep_the_first_one() {
    let s = Server::start();
    let (old, new) = ("1".repeat(40), "2".repeat(40));
    s.put(
        "/repos/acme/dup/tags",
        json!([{ "name": "v1.0.0", "commit": { "sha": old } }, { "name": "1.0.0", "commit": { "sha": new } }]).to_string(),
    );
    s.put(&format!("/repos/acme/dup/commits/{old}"), gh_commit(&old, 240).to_string());
    s.put(&format!("/repos/acme/dup/commits/{new}"), gh_commit(&new, 1).to_string());
    s.put(&format!("/repos/acme/dup/zipball/{old}"), zipball(&[("SKILL.md", &skill_md("dup"))]));
    s.put(&format!("/repos/acme/dup/zipball/{new}"), zipball(&[("SKILL.md", &skill_md("dup"))]));
    let p = with_github(Project::new(&s), &s);
    p.manifest(&s, "");
    p.ok(&["add", "github:acme/dup"]);
    let lock = p.read("skills.lock");
    assert!(lock.contains(&format!("zipball/{old}")) && lock.contains("version = \"v1.0.0\""), "{lock}");
}

fn host(s: &Server) -> String {
    s.base.trim_start_matches("https://").to_string()
}

/// Trusts the test CAs of several servers at once.
fn trust(p: &mut Project, servers: &[&Server]) {
    let pem: String = servers.iter().map(|s| std::fs::read_to_string(&s.ca_file).unwrap()).collect();
    let file = p.home().join("ca-bundle.pem");
    std::fs::write(&file, pem).unwrap();
    p.env.push(("SKILLCASK_CA_FILE".into(), file.display().to_string()));
}

#[test]
fn bare_host_credentials_are_not_sent_to_another_port() {
    let s = Server::start();
    s.simple("acme/one", "1.0.0", "one");
    let mut p = Project::new(&s);
    p.manifest(&s, "\"acme/one\" = \"^1.0\"\n");
    p.env.push(("COMPOSER_AUTH".into(), json!({ "bearer": { "127.0.0.1": "t0ken" } }).to_string()));
    p.ok(&["install"]);
    assert!(s.log().iter().all(|l| l.ends_with("auth=false")), "{:?}", s.log());
}

#[test]
fn gitlab_token_string_and_object_forms() {
    let s = Server::start();
    s.simple("acme/one", "1.0.0", "one");
    let mut p = Project::new(&s);
    p.manifest(&s, "\"acme/one\" = \"^1.0\"\n");
    p.env.push(("COMPOSER_AUTH".into(), json!({ "gitlab-token": { host(&s): "pt0ken" } }).to_string()));
    p.ok(&["install"]);
    let reqs = s.requests();
    assert!(
        reqs.iter()
            .all(|r| r.headers.get("private-token").map(String::as_str) == Some("pt0ken") && !r.headers.contains_key("authorization")),
        "{reqs:?}"
    );

    s.require_auth(Some("Basic dTp0MGtlbg=="));
    let mut c = clone_of(&p, &s);
    c.env.push(("COMPOSER_AUTH".into(), json!({ "gitlab-token": { host(&s): { "username": "u", "token": "t0ken" } } }).to_string()));
    c.ok(&["install"]);
}

#[test]
fn userinfo_in_a_repository_url_is_sent_as_basic_auth() {
    let s = Server::start();
    s.simple("acme/one", "1.0.0", "one");
    let p = Project::new(&s);
    p.manifest(&s, "\"acme/one\" = \"^1.0\"\n");
    let toml = p.read("skills.toml").replace("https://", "https://u:p@");
    p.write("skills.toml", &toml);
    p.ok(&["install"]);
    let reqs = s.requests();
    let basic = |r: &Request| r.headers.get("authorization").map(String::as_str) == Some("Basic dTpw");
    assert!(reqs.iter().any(|r| r.path == "/packages.json" && basic(r)), "{reqs:?}");
    // The dist URL loses the userinfo (registry.rs), so the zip goes without it.
    let zips: Vec<_> = reqs.iter().filter(|r| r.path.ends_with(".zip")).collect();
    assert!(!zips.is_empty() && zips.iter().all(|r| !r.headers.contains_key("authorization")), "{reqs:?}");
}

#[test]
fn github_token_goes_to_the_api_host_only() {
    let gh = Server::start();
    let repo = Server::start();
    repo.simple("acme/one", "1.0.0", "one");
    let sha = "1".repeat(40);
    gh.put("/repos/acme/t/tags", json!([{ "name": "v1.0.0", "commit": { "sha": sha } }]).to_string());
    gh.put(&format!("/repos/acme/t/commits/{sha}"), gh_commit(&sha, 240).to_string());
    gh.put(&format!("/repos/acme/t/zipball/{sha}"), zipball(&[("SKILL.md", &skill_md("t"))]));
    gh.require_auth(Some("Bearer ght0ken"));
    let mut p = with_github(Project::new(&repo), &gh);
    trust(&mut p, &[&gh, &repo]);
    p.env.push(("GITHUB_TOKEN".into(), "ght0ken".into()));
    p.manifest(&repo, "");
    p.ok(&["add", "acme/one"]);
    p.ok(&["add", "github:acme/t"]);
    assert!(!repo.log().is_empty() && repo.log().iter().all(|l| l.ends_with("auth=false")), "{:?}", repo.log());
}

#[test]
fn github_token_never_follows_a_github_url_from_the_manifest() {
    let gh = Server::start();
    let sha = "1".repeat(40);
    gh.put("/repos/acme/t/tags", json!([{ "name": "v1.0.0", "commit": { "sha": sha } }]).to_string());
    gh.put(&format!("/repos/acme/t/commits/{sha}"), gh_commit(&sha, 240).to_string());
    gh.put(&format!("/repos/acme/t/zipball/{sha}"), zipball(&[("SKILL.md", &skill_md("t"))]));
    let mut p = Project::new(&gh);
    p.env.push(("GITHUB_TOKEN".into(), "ght0ken".into()));
    p.write("skills.toml", &format!("[repositories]\npackagist = false\ngithub = {{ type = \"github\", url = \"{}\" }}\n", gh.base));
    p.ok(&["add", "github:acme/t"]);
    assert!(!gh.log().is_empty() && gh.log().iter().all(|l| l.ends_with("auth=false")), "{:?}", gh.log());
    let e = p.expect(&["add", "github:acme/private"], 1);
    assert!(e.contains("skillcask auth set") && !e.contains("GITHUB_TOKEN"), "{e}");

    // GitHub Actions names its API (GitHub Enterprise on a GHE runner); that host gets the token.
    std::fs::remove_file(p.path().join("skills.lock")).unwrap();
    p.env.push(("GITHUB_API_URL".into(), gh.base.clone()));
    p.ok(&["update"]);
    assert!(gh.log().iter().any(|l| l.ends_with("auth=true")), "{:?}", gh.log());
}

#[test]
fn an_enforced_github_source_is_not_widened_by_the_manifest() {
    let gh = Server::start();
    let p = Project::new(&gh);
    p.config("[policy]\nallow-sources = [\"github\"]\nenforce = [\"allow-sources\"]\n");
    p.write("skills.toml", &format!("[repositories]\npackagist = false\ngithub = {{ type = \"github\", url = \"{}\" }}\n", gh.base));
    let e = p.expect(&["add", "github:acme/t"], 1);
    assert!(e.contains("not in policy.allow-sources") && e.contains("\"github\" there means https://api.github.com"), "{e}");
    assert!(gh.log().is_empty(), "{:?}", gh.log());
}

#[test]
fn an_enforced_github_source_is_public_github_only() {
    let gh = Server::start();
    let sha = "1".repeat(40);
    gh.put("/repos/acme/t/tags", json!([{ "name": "v1.0.0", "commit": { "sha": sha } }]).to_string());
    gh.put(&format!("/repos/acme/t/commits/{sha}"), gh_commit(&sha, 240).to_string());
    gh.put(&format!("/repos/acme/t/zipball/{sha}"), zipball(&[("SKILL.md", &skill_md("t"))]));
    // Regression: the environment's API used to be what an enforced "github" allowed, and
    // GITHUB_TOKEN went along to it.
    let mut p = with_github(Project::new(&gh), &gh);
    p.env.push(("GITHUB_TOKEN".into(), "ght0ken".into()));
    p.config("[policy]\nallow-sources = [\"github\"]\nenforce = [\"allow-sources\"]\n");
    p.write("skills.toml", "[repositories]\npackagist = false\n");
    let e = p.expect(&["add", "github:acme/t"], 1);
    assert!(e.contains("\"github\" there means https://api.github.com"), "{e}");
    p.env.retain(|(k, _)| k != "SKILLCASK_GITHUB_API");
    p.env.push(("GITHUB_API_URL".into(), gh.base.clone()));
    p.write("skills.toml", &format!("[repositories]\npackagist = false\ngithub = {{ type = \"github\", url = \"{}\" }}\n", gh.base));
    p.expect(&["add", "github:acme/t"], 1);
    assert!(gh.log().is_empty(), "{:?}", gh.log());
    // Nor can the environment name it as a prefix inside the enforced alias.
    p.env.push(("SKILLCASK_ALLOW_SOURCES".into(), format!("{}/repos/", gh.base)));
    assert!(p.expect(&["status"], 1).contains("loosens policy.allow-sources"));

    // GitHub Enterprise is enforced by its prefix.
    p.env.retain(|(k, _)| k != "SKILLCASK_ALLOW_SOURCES" && k != "SKILLCASK_GITHUB_API");
    p.env.push(("SKILLCASK_GITHUB_API".into(), gh.base.clone()));
    p.config(&format!("[policy]\nallow-sources = [\"{}/repos/\"]\nenforce = [\"allow-sources\"]\n", gh.base));
    p.ok(&["add", "github:acme/t"]);
}

#[test]
fn a_locked_dist_outside_its_github_repository_is_refused() {
    let (gh, evil) = (Server::start(), Server::start());
    let sha = "1".repeat(40);
    gh.put("/repos/acme/t/tags", json!([{ "name": "v1.0.0", "commit": { "sha": sha } }]).to_string());
    gh.put(&format!("/repos/acme/t/commits/{sha}"), gh_commit(&sha, 240).to_string());
    let zip = zipball(&[("SKILL.md", &skill_md("t"))]);
    gh.put(&format!("/repos/acme/t/zipball/{sha}"), zip.clone());
    gh.put(&format!("/repos/evil/x/zipball/{sha}"), zip.clone());
    evil.put(&format!("/repos/acme/t/zipball/{sha}"), zip);
    let p = with_github(Project::new(&gh), &gh);
    p.config(&format!("[policy]\nallow-sources = [\"{}/repos/acme/\"]\nenforce = [\"allow-sources\"]\n", gh.base));
    p.write("skills.toml", "[repositories]\npackagist = false\n");
    p.ok(&["add", "github:acme/t"]);
    let good = p.read("skills.lock");
    let zipball = format!("{}/repos/acme/t/zipball/{sha}", gh.base);
    assert!(good.contains(&zipball), "{good}");
    let tamper = |lock: &str| {
        p.write("skills.lock", lock);
        let _ = std::fs::remove_dir_all(p.path().join(".agents"));
    };

    // Regression: only `repository` was held to allow-sources; `dist.url` was fetched as written.
    let moved = good.replace(&zipball, &format!("{}/repos/acme/t/zipball/{sha}", evil.base));
    tamper(&moved);
    let e = p.expect(&["install", "--frozen"], 1);
    assert!(e.contains("dist zip") && e.contains(&format!("is not zip {zipball}")), "{e}");
    for args in [&["install"][..], &["info", "acme/t"], &["diff", "acme/t", "--to", "1.0.0"]] {
        let e = p.expect(args, 1);
        assert!(e.contains("dist zip"), "{args:?}: {e}");
    }
    // `update` resolves again rather than taking the lock's dist; it must not fetch that either.
    tamper(&moved);
    p.ok(&["update", "--diff"]);
    // `diff --from` shows the base lock's version from its archive when it is not installed.
    let at = moved.find("dist-sha256 = \"").unwrap() + "dist-sha256 = \"".len();
    p.write("base.lock", &format!("{}{}{}", &moved[..at], "0".repeat(64), &moved[at + 64..]));
    tamper(&good);
    let e = p.expect(&["diff", "--from", "base.lock"], 1);
    assert!(e.contains("dist zip"), "{e}");
    assert!(evil.log().is_empty(), "{:?}", evil.log());

    // Regression: `..` in the reference left the enforced prefix for another repository on the host.
    let up = format!("../../../evil/x/zipball/{sha}");
    tamper(
        &good
            .replace(&zipball, &format!("{}/repos/acme/t/zipball/{up}", gh.base))
            .replace(&format!("reference = \"{sha}\""), &format!("reference = \"{up}\"")),
    );
    assert!(p.expect(&["install", "--frozen"], 1).contains("dist zip"));
    assert!(!gh.log().iter().any(|l| l.contains("/repos/evil/")), "{:?}", gh.log());
}

#[test]
fn a_locked_dist_of_a_registry_admitted_by_a_prefix_stays_under_allow_sources() {
    let (reg, evil) = (Server::start(), Server::start());
    reg.simple("acme/x", "1.0.0", "x");
    evil.put("/dist/acme/x/1.0.0.zip", zipball(&[("SKILL.md", &skill_md("x")), ("scripts/run.sh", "#!/bin/sh\necho hi\n")]));
    let p = Project::new(&reg);
    p.config(&format!("[policy]\nallow-sources = [\"{}/\"]\nenforce = [\"allow-sources\"]\n", reg.base));
    p.manifest(&reg, "");
    p.ok(&["add", "acme/x"]);
    let dist = reg.url("/dist/acme/x/1.0.0.zip");
    let good = p.read("skills.lock");
    assert!(good.contains(&dist), "{good}");

    // Regression: a project's own registry under an allowed prefix downloaded its dist from any host.
    p.write("skills.lock", &good.replace(&dist, &evil.url("/dist/acme/x/1.0.0.zip")));
    let _ = std::fs::remove_dir_all(p.path().join(".agents"));
    let e = p.expect(&["install", "--frozen"], 1);
    assert!(e.contains("is not in policy.allow-sources"), "{e}");
    assert!(evil.log().is_empty(), "{:?}", evil.log());
}

#[test]
fn github_rate_limit_is_named() {
    let s = Server::start();
    s.respond("/repos/acme/x/tags", 403, &[("x-ratelimit-remaining", "0")], "");
    let p = with_github(Project::new(&s), &s);
    p.manifest(&s, "");
    let out = p.expect(&["add", "github:acme/x"], 2);
    assert!(out.contains("GitHub API rate limit reached; set GITHUB_TOKEN"), "{out}");
}

#[test]
fn ref_fallback_rejects_a_commit_newer_than_the_cutoff() {
    let s = Server::start();
    let (a, b) = ("a".repeat(40), "b".repeat(40));
    s.put("/repos/acme/r/commits/main", gh_commit(&a, 1).to_string());
    s.put("/repos/acme/r/commits", json!([gh_commit(&b, 2)]).to_string());
    s.put(&format!("/repos/acme/r/zipball/{b}"), zipball(&[("SKILL.md", &skill_md("r"))]));
    let p = with_github(Project::new(&s), &s);
    p.manifest(&s, "");
    let out = p.expect(&["add", "github:acme/r@main"], 1);
    assert!(out.contains("min-release-age"), "{out}");
    assert!(!p.exists("skills.lock"));
}

#[test]
fn github_404_names_the_token_when_none_is_set() {
    let s = Server::start();
    let mut p = with_github(Project::new(&s), &s);
    p.manifest(&s, "");
    let out = p.expect(&["add", "github:acme/private"], 1);
    assert!(out.contains("private repositories need GITHUB_TOKEN"), "{out}");
    p.env.push(("GITHUB_TOKEN".into(), "t".into()));
    let out = p.expect(&["add", "github:acme/private"], 1);
    assert!(out.contains("not found") && !out.contains("GITHUB_TOKEN"), "{out}");
}

fn hundred_tags(sha: &str) -> String {
    json!((0..100).map(|i| json!({ "name": format!("v1.0.{i}"), "commit": { "sha": sha } })).collect::<Vec<_>>()).to_string()
}

#[test]
fn tags_on_a_second_page_are_read() {
    let s = Server::start();
    let (old, top) = ("1".repeat(40), "2".repeat(40));
    s.respond("/repos/acme/p/tags?per_page=100&page=1", 200, &[], hundred_tags(&old));
    s.respond("/repos/acme/p/tags?per_page=100&page=2", 200, &[], json!([{ "name": "v2.0.0", "commit": { "sha": top } }]).to_string());
    s.put(&format!("/repos/acme/p/commits/{top}"), gh_commit(&top, 240).to_string());
    s.put(&format!("/repos/acme/p/zipball/{top}"), zipball(&[("SKILL.md", &skill_md("p"))]));
    let p = with_github(Project::new(&s), &s);
    p.manifest(&s, "");
    p.ok(&["add", "github:acme/p"]);
    assert!(p.read("skills.lock").contains("version = \"v2.0.0\""), "{}", p.read("skills.lock"));
}

#[test]
fn tags_beyond_the_page_limit_are_warned_about() {
    let s = Server::start();
    let sha = "1".repeat(40);
    s.put("/repos/acme/many/tags", hundred_tags(&sha));
    s.put(&format!("/repos/acme/many/commits/{sha}"), gh_commit(&sha, 240).to_string());
    s.put(&format!("/repos/acme/many/zipball/{sha}"), zipball(&[("SKILL.md", &skill_md("many"))]));
    let p = with_github(Project::new(&s), &s);
    p.manifest(&s, "");
    let out = p.ok(&["add", "github:acme/many"]);
    assert!(out.contains("warning") && out.contains("1000 tags"), "{out}");
}

#[test]
fn cross_host_redirect_drops_credentials() {
    let a = Server::start();
    let b = Server::start();
    b.simple("acme/one", "1.0.0", "one");
    for path in ["/packages.json", "/p2/acme/one.json"] {
        a.redirect(path, &b.url(path));
    }
    a.require_auth(Some("Bearer t0ken"));
    let mut p = Project::new(&a);
    trust(&mut p, &[&a, &b]);
    p.env.push(("COMPOSER_AUTH".into(), json!({ "bearer": { host(&a): "t0ken" } }).to_string()));
    p.manifest(&a, "\"acme/one\" = \"^1.0\"\n");
    p.ok(&["install"]);
    assert!(a.log().iter().all(|l| l.ends_with("auth=true")), "{:?}", a.log());
    assert!(!b.log().is_empty() && b.requests().iter().all(|r| !r.headers.contains_key("authorization")), "{:?}", b.log());
}

#[test]
fn redirect_to_plain_http_is_refused_before_connecting() {
    let s = Server::start();
    let plain = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    s.redirect("/packages.json", &format!("http://127.0.0.1:{}/packages.json", plain.local_addr().unwrap().port()));
    let p = Project::new(&s);
    p.manifest(&s, "\"acme/one\" = \"^1.0\"\n");
    let out = p.expect(&["install"], 3);
    assert!(out.contains("refusing non-HTTPS"), "{out}");
    plain.set_nonblocking(true).unwrap();
    assert_eq!(plain.accept().unwrap_err().kind(), std::io::ErrorKind::WouldBlock, "no plain HTTP connection");
}

#[test]
fn more_than_five_redirects_fail() {
    let s = Server::start();
    s.redirect("/packages.json", "/r1");
    for i in 1..=6 {
        s.redirect(&format!("/r{i}"), &format!("/r{}", i + 1));
    }
    let p = Project::new(&s);
    p.manifest(&s, "\"acme/one\" = \"^1.0\"\n");
    let out = p.expect(&["install"], 3);
    assert!(out.contains("more than 5 redirects"), "{out}");
    assert_eq!(s.log().len(), 6, "{:?}", s.log());
}

#[test]
fn composer_404_names_auth_set_once_when_no_token_is_set() {
    let s = Server::start();
    let p = Project::new(&s);
    p.manifest(&s, "");
    let host = s.base.trim_start_matches("https://").to_string();
    let out = p.expect(&["search", "x"], 3);
    assert!(out.contains(&format!("skillcask auth set {host}")), "{out}");
    // search used to prefix the repository name a second time
    assert!(!out.contains("repository fix: repository fix:"), "{out}");
    p.write("auth.json", &json!({ "bearer": { host: "t0ken" } }).to_string());
    let out = p.expect(&["add", "acme/one"], 3);
    assert!(out.contains("not found") && !out.contains("auth set"), "{out}");
}
