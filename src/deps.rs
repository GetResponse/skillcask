//! Dependencies between skills: `requires:` in SKILL.md, locked per package (D16).

use std::collections::{BTreeMap, BTreeSet};

use crate::bail;
use crate::error::{MANIFEST, Result};
use crate::lock::Lock;
use crate::manifest::{self, GitHub, Manifest, Policy, SkillReq};
use crate::skill::valid_name;
use crate::version::Constraint;

/// What a `requires:` key names.
#[derive(Clone, Debug, PartialEq)]
pub enum Target {
    Composer(String),
    GitHub {
        repo: String,
        skill: Option<String>,
    },
    /// A plain git repository (D30): `repo` is the entry name from the URL's last two parts.
    Git {
        url: String,
        repo: String,
        skill: Option<String>,
    },
}

impl Target {
    /// The lock and manifest name.
    pub fn package(&self) -> &str {
        match self {
            Target::Composer(n) | Target::GitHub { repo: n, .. } | Target::Git { repo: n, .. } => n,
        }
    }
}

/// `vendor/name`, `github:owner/repo[/skill]` or `git:https://host/owner/repo.git[#skill]`.
pub fn target(key: &str) -> std::result::Result<Target, String> {
    let bad = || format!("{key:?} is not a package (vendor/name), github:owner/repo[/skill] or git:https://…[#skill]");
    if let Some(rest) = key.strip_prefix("git:") {
        let (url, skill) = rest.split_once('#').map_or((rest, None), |(u, s)| (u, Some(s.to_string())));
        let url = url.trim_end_matches('/');
        crate::git::check_url(url).map_err(|e| format!("{key:?}: {e}"))?;
        let repo = crate::git::name_of(url).ok_or_else(bad)?;
        if skill.as_deref().is_some_and(|s| !valid_name(s)) {
            return Err(bad());
        }
        return Ok(Target::Git { url: url.to_string(), repo, skill });
    }
    let Some(rest) = key.strip_prefix("github:") else {
        return manifest::valid_package_name(key).then(|| Target::Composer(key.to_string())).ok_or_else(bad);
    };
    let mut parts = rest.splitn(3, '/');
    let repo = format!("{}/{}", parts.next().unwrap_or(""), parts.next().unwrap_or("")).to_lowercase();
    let skill = parts.next().map(String::from);
    if !manifest::valid_package_name(&repo) || skill.as_deref().is_some_and(|s| !valid_name(s)) {
        return Err(bad());
    }
    Ok(Target::GitHub { repo, skill })
}

/// One `requires:` entry. A GitHub value is a constraint over tags when it parses as one, else a
/// ref, as in `add github:`.
pub fn check(key: &str, value: &str) -> std::result::Result<(Target, Option<GitHub>), String> {
    let t = target(key)?;
    let mode = match t {
        Target::Composer(_) => None,
        Target::GitHub { .. } | Target::Git { .. } if Constraint::parse(value).is_ok() => Some(GitHub::Tags),
        Target::GitHub { .. } | Target::Git { .. } => Some(GitHub::Ref),
    };
    let req = SkillReq { name: t.package().into(), constraint: value.into(), github: mode, ..Default::default() };
    // The consumer's allow-ranges applies to its own manifest only; the lock pins the version.
    let any = Policy {
        min_release_age: Default::default(),
        allow_ranges: true,
        packagist: true,
        github_requires: true,
        deny_patterns: false,
        allow_sources: None,
        deny_packages: Vec::new(),
        github_public: false,
        effective: Default::default(),
    };
    manifest::check_constraint(&req, &any).map_err(|e| format!("{key}: {e}"))?;
    Ok((t, mode))
}

/// Adds the `requires:` of one SKILL.md to a package's `acc`; a key two skills share gets both
/// constraints.
pub fn collect(acc: &mut BTreeMap<String, String>, skill_md: &str) -> std::result::Result<(), String> {
    for (k, v) in crate::skill::requires(skill_md)? {
        check(&k, &v)?;
        let v = match acc.remove(&k) {
            Some(prev) => intersect(&[prev, v])?,
            None => v,
        };
        acc.insert(k, v);
    }
    Ok(())
}

/// The Composer AND of `cs`: sorted, deduplicated, distributed over `||` (which binds looser
/// than `,`). A single constraint is returned as written.
pub fn intersect(cs: &[String]) -> std::result::Result<String, String> {
    let mut cs: Vec<&str> = cs.iter().map(|c| c.trim()).collect();
    cs.sort();
    cs.dedup();
    if let [one] = cs[..] {
        return Ok(one.to_string());
    }
    let mut out = vec![String::new()];
    for c in cs {
        let groups: Vec<&str> = c.split('|').map(str::trim).filter(|g| !g.is_empty()).collect();
        // ponytail: `a - b` only parses alone in a group; rewrite it as `>=a <b` if anyone needs it combined.
        if groups.iter().any(|g| g.contains(" - ")) {
            return Err(format!("the hyphen range {c:?} cannot be combined with another constraint; use >= and <"));
        }
        out = out.iter().flat_map(|a| groups.iter().map(move |g| if a.is_empty() { g.to_string() } else { format!("{a}, {g}") })).collect();
    }
    Ok(out.join(" || "))
}

/// Requirements in effect: manifest entries with the constraints their requirers add, then every
/// package required by them, transitively through the lock.
#[derive(Debug)]
pub struct Wanted {
    pub reqs: Vec<SkillReq>,
    /// Package → (requirer, constraint as written), for dependencies and required manifest entries.
    pub by: BTreeMap<String, Vec<(String, String)>>,
}

struct Ask {
    requirer: String,
    key: String,
    value: String,
    mode: Option<GitHub>,
    /// The plain git URL, for a `git:` key.
    git: Option<String>,
    skill: Option<String>,
}

pub fn wanted(m: &Manifest, lock: &Lock) -> Result<Wanted> {
    let mut asks: BTreeMap<String, Vec<Ask>> = BTreeMap::new();
    let mut seen: BTreeSet<String> = m.skills.iter().map(|r| r.name.clone()).collect();
    let mut queue: Vec<String> = seen.iter().cloned().collect();
    // Only requirements of reachable packages count, so orphans do not keep each other alive.
    while let Some(n) = queue.pop() {
        let Some(p) = lock.get(&n) else { continue };
        for (key, value) in &p.requires {
            let (t, mode) = check(key, value).map_err(|e| crate::error::Error::new(MANIFEST, format!("{n}: {e}")))?;
            let dep = t.package().to_string();
            let (git, skill) = match t {
                Target::GitHub { skill, .. } => (None, skill),
                Target::Git { url, skill, .. } => (Some(url), skill),
                Target::Composer(_) => (None, None),
            };
            asks.entry(dep.clone()).or_default().push(Ask {
                requirer: n.clone(),
                key: key.clone(),
                value: value.clone(),
                mode,
                git,
                skill,
            });
            if seen.insert(dep.clone()) {
                queue.push(dep);
            }
        }
    }
    for a in asks.values_mut() {
        a.sort_by(|x, y| x.requirer.cmp(&y.requirer));
    }
    let mut reqs: Vec<SkillReq> = Vec::new();
    for base in &m.skills {
        reqs.push(match asks.get(&base.name) {
            Some(a) => merge(m, &base.name, Some(base), a)?,
            None => base.clone(),
        });
    }
    for (name, a) in asks.iter().filter(|(n, _)| m.skill(n).is_none()) {
        reqs.push(merge(m, name, None, a)?);
    }
    let by = asks.into_iter().map(|(n, a)| (n, a.into_iter().map(|a| (a.requirer, a.value)).collect())).collect();
    Ok(Wanted { reqs, by })
}

fn merge(m: &Manifest, name: &str, base: Option<&SkillReq>, asks: &[Ask]) -> Result<SkillReq> {
    let mut who: Vec<String> = base.iter().map(|b| format!("{}: {:?}", manifest::FILE, b.constraint)).collect();
    who.extend(asks.iter().map(|a| format!("{} requires {} {:?}", a.requirer, a.key, a.value)));
    let conflict = |what: &str| crate::error::Error::new(MANIFEST, format!("{name}: {what}:\n  {}", who.join("\n  ")));
    let mode = asks[0].mode;
    if asks.iter().any(|a| a.mode != mode) || base.is_some_and(|b| b.github != mode) {
        return Err(conflict("required as different kinds of source (Composer, GitHub tags, GitHub ref)"));
    }
    let git = &asks[0].git;
    if asks.iter().any(|a| &a.git != git) || base.is_some_and(|b| &b.git != git) {
        return Err(conflict("required from different repositories (GitHub or git URLs)"));
    }
    // A GitHub or git entry in the manifest is the consumer's own decision already.
    if mode.is_some() && base.is_none() && !m.policy.github_requires {
        let what = if git.is_some() { "a git source" } else { "a GitHub source" };
        bail!(
            MANIFEST,
            "{} requires {}, {what}; allow GitHub and git dependencies with `github-requires = true` under [policy] in {}, or add it to [skills] yourself",
            asks[0].requirer,
            asks[0].key,
            manifest::FILE
        );
    }
    let mut constraints: Vec<String> = base.iter().map(|b| b.constraint.clone()).collect();
    constraints.extend(asks.iter().map(|a| a.value.clone()));
    let constraint = if mode == Some(GitHub::Ref) {
        constraints.sort();
        constraints.dedup();
        if constraints.len() > 1 {
            return Err(conflict("required at different refs"));
        }
        constraints.remove(0)
    } else {
        intersect(&constraints).map_err(|e| conflict(&e))?
    };
    let wanted_skills: Option<BTreeSet<&String>> =
        if asks.iter().any(|a| a.skill.is_none()) { None } else { Some(asks.iter().filter_map(|a| a.skill.as_ref()).collect()) };
    let skills = match (base, wanted_skills) {
        // D44: requirers widen the manifest's selection, as they do for a package without an entry.
        (Some(b), want) => match (&b.skills, want) {
            (Some(sel), Some(w)) => {
                let mut all: BTreeSet<String> = sel.iter().cloned().collect();
                all.extend(w.into_iter().cloned());
                Some(all.into_iter().collect())
            }
            _ => None,
        },
        (None, want) => want.map(|w| w.into_iter().cloned().collect()),
    };
    let mut req =
        base.cloned().unwrap_or_else(|| SkillReq { name: name.to_string(), github: mode, git: git.clone(), ..Default::default() });
    req.constraint = constraint;
    req.skills = skills;
    Ok(req)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_targets() {
        assert_eq!(target("acme/x"), Ok(Target::Composer("acme/x".into())));
        assert_eq!(target("github:Owner/Repo/pr"), Ok(Target::GitHub { repo: "owner/repo".into(), skill: Some("pr".into()) }));
        assert_eq!(target("github:o/r"), Ok(Target::GitHub { repo: "o/r".into(), skill: None }));
        let url = "https://git.example.com/team/skills.git";
        assert_eq!(
            target(&format!("git:{url}#pr")),
            Ok(Target::Git { url: url.into(), repo: "team/skills".into(), skill: Some("pr".into()) })
        );
        assert_eq!(target(&format!("git:{url}/")).unwrap().package(), "team/skills");
        for bad in [
            "acme",
            "Acme/x",
            "github:a",
            "github:a/b/Bad_Skill",
            "gitlab:a/b",
            "git:http://h/a/b",
            "git:https://h/a",
            "git:https://h/a/b#Bad",
        ] {
            assert!(target(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn checks_values() {
        assert_eq!(check("github:o/r", "^1").unwrap().1, Some(GitHub::Tags));
        assert_eq!(check("github:o/r", "main").unwrap().1, Some(GitHub::Ref));
        assert!(check("github:o/r", "a..b").is_err());
        assert_eq!(check("acme/x", "^1.0").unwrap().1, None);
        assert!(check("acme/x", "main").is_err());
    }

    #[test]
    fn intersects_constraints() {
        let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        assert_eq!(intersect(&s(&["^1.2", "^1.0"])).unwrap(), "^1.0, ^1.2");
        assert_eq!(intersect(&s(&["^1 || ^2", "^2.1"])).unwrap(), "^1, ^2.1 || ^2, ^2.1");
        assert_eq!(intersect(&s(&["1.0 - 2.0"])).unwrap(), "1.0 - 2.0");
        assert_eq!(intersect(&s(&["^1", "^1"])).unwrap(), "^1");
        assert!(intersect(&s(&["1.0 - 2.0", "^1"])).is_err());
        let c = Constraint::parse(&intersect(&s(&["^1 || ^2", "^2.1"])).unwrap()).unwrap();
        let v = |x: &str| crate::version::Version::parse(x).unwrap();
        assert!(c.allows(&v("2.3.0")) && !c.allows(&v("2.0.0")) && !c.allows(&v("1.5.0")));
    }

    fn manifest(skills: &str, policy: &str) -> Manifest {
        manifest::parse(&format!("[skills]\n{skills}\n[policy]\npackagist = false\n{policy}\n"), false).unwrap()
    }

    fn lock(packages: &[(&str, &str, &str)]) -> Lock {
        let h = "a".repeat(64);
        let mut t = String::from("version = 2\n");
        for (name, constraint, requires) in packages {
            t.push_str(&format!(
                "[[package]]\nname = \"{name}\"\nconstraint = \"{constraint}\"\nversion = \"1.0.0\"\nrepository = \"https://r\"\ndist = {{ type = \"zip\", url = \"https://d\" }}\ndist-sha256 = \"{h}\"\nrequires = {{ {requires} }}\nskills = []\n"
            ));
        }
        crate::lock::parse(&t).unwrap()
    }

    #[test]
    fn no_requires_is_the_manifest() {
        let m = manifest("\"acme/a\" = \"^1\"", "");
        let w = wanted(&m, &lock(&[("acme/a", "^1", "")])).unwrap();
        assert_eq!(w.reqs, m.skills);
        assert!(w.by.is_empty());
    }

    #[test]
    fn dependencies_are_added_and_intersected() {
        let m = manifest("\"acme/a\" = \"^1\"\n\"acme/b\" = \"^1\"", "");
        let l = lock(&[
            ("acme/a", "^1", "\"acme/c\" = \"^1.2\", \"acme/b\" = \"^1.1\""),
            ("acme/b", "^1", "\"acme/c\" = \"^1.0\""),
            ("acme/orphan", "^1", "\"acme/z\" = \"^1\""),
        ]);
        let w = wanted(&m, &l).unwrap();
        let names: Vec<&str> = w.reqs.iter().map(|r| r.name.as_str()).collect();
        assert_eq!(names, ["acme/a", "acme/b", "acme/c"]);
        assert_eq!(w.reqs[1].constraint, "^1, ^1.1");
        assert_eq!(w.reqs[2].constraint, "^1.0, ^1.2");
        assert_eq!(w.by["acme/c"].len(), 2);
        assert!(!w.by.contains_key("acme/z"));
    }

    #[test]
    fn github_dependencies_need_the_policy_and_one_ref() {
        let m = manifest("\"acme/a\" = \"^1\"", "");
        let l = lock(&[("acme/a", "^1", "\"github:o/r/pr\" = \"main\"")]);
        assert!(wanted(&m, &l).unwrap_err().msg.contains("github-requires = true"));
        let m = manifest("\"acme/a\" = \"^1\"\n\"acme/b\" = \"^1\"", "github-requires = true");
        let w = wanted(&m, &l).unwrap();
        let gh = w.reqs.iter().find(|r| r.name == "o/r").unwrap();
        assert_eq!((gh.github, gh.constraint.as_str(), gh.skills.clone()), (Some(GitHub::Ref), "main", Some(vec!["pr".to_string()])));
        let l = lock(&[("acme/a", "^1", "\"github:o/r/pr\" = \"main\""), ("acme/b", "^1", "\"github:o/r\" = \"dev\"")]);
        assert!(wanted(&m, &l).unwrap_err().msg.contains("different refs"));
        let l = lock(&[("acme/a", "^1", "\"github:o/r/pr\" = \"main\""), ("acme/b", "^1", "\"o/r\" = \"^1\"")]);
        assert!(wanted(&m, &l).unwrap_err().msg.contains("different kinds"));
    }

    #[test]
    fn git_dependencies_need_the_policy_and_one_url() {
        let a = "\"git:https://git.example.com/o/r.git#pr\" = \"^1\"";
        let m = manifest("\"acme/a\" = \"^1\"", "");
        assert!(wanted(&m, &lock(&[("acme/a", "^1", a)])).unwrap_err().msg.contains("a git source"));
        let m = manifest("\"acme/a\" = \"^1\"\n\"acme/b\" = \"^1\"", "github-requires = true");
        let w = wanted(&m, &lock(&[("acme/a", "^1", a)])).unwrap();
        let r = w.reqs.iter().find(|r| r.name == "o/r").unwrap();
        assert_eq!(
            (r.git.as_deref(), r.github, r.skills.clone()),
            (Some("https://git.example.com/o/r.git"), Some(GitHub::Tags), Some(vec!["pr".to_string()]))
        );
        let b = "\"git:https://other.example.com/o/r.git\" = \"^1\"";
        assert!(wanted(&m, &lock(&[("acme/a", "^1", a), ("acme/b", "^1", b)])).unwrap_err().msg.contains("different repositories"));
        let gh = "\"github:o/r\" = \"^1\"";
        assert!(wanted(&m, &lock(&[("acme/a", "^1", a), ("acme/b", "^1", gh)])).unwrap_err().msg.contains("different repositories"));
    }

    #[test]
    fn requirers_widen_a_manifest_selection() {
        let m = manifest("\"acme/a\" = \"^1\"\n\"o/r\" = { github = true, ref = \"main\", skills = [\"tdd\"] }", "github-requires = true");
        let skills_of = |l| wanted(&m, &l).unwrap().reqs.into_iter().find(|r| r.name == "o/r").unwrap().skills;
        assert_eq!(skills_of(lock(&[("acme/a", "^1", "\"github:o/r/pr\" = \"main\"")])), Some(vec!["pr".to_string(), "tdd".to_string()]));
        assert_eq!(skills_of(lock(&[("acme/a", "^1", "\"github:o/r\" = \"main\"")])), None);
    }
}
