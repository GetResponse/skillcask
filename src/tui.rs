//! `skillcask ui` (D41): a terminal UI that holds no package logic. Every step runs this binary
//! as a child and reads its `--json` documents or shows its output.

use std::collections::HashMap;
use std::io::{IsTerminal, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use ratatui::crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use ratatui::layout::{Constraint, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, List, ListItem, ListState, Paragraph, Wrap};
use ratatui::{DefaultTerminal, Frame};
use serde_json::Value;

use crate::error::{Error, IO, MANIFEST, Result};

/// Keys that do not depend on the selected row; those that do are listed in the actions box.
const HELP: [&str; 15] = [
    "↑↓/jk move",
    "pgup/pgdn scroll",
    "tab info/audit/output",
    "g project/global",
    "i install",
    "a add",
    "o doctor",
    "f doctor --fix",
    "/ filter list",
    "s search registries",
    "p find projects",
    "R repositories",
    "S skills.sh on/off",
    "r refresh",
    "q quit",
];
const SKILL_MD_MAX: u64 = 256 * 1024;

pub fn run(global: bool) -> Result<()> {
    if !std::io::stdout().is_terminal() {
        return Err(
            Error::new(MANIFEST, "skillcask ui needs a terminal").hint("in scripts use status, outdated, info or audit with --json")
        );
    }
    let project = crate::project::find_root().ok();
    let global = global || project.is_none();
    let mut app = App::new(std::env::current_exe()?, std::env::current_dir()?, project, global, crate::scope::home());
    // try_init also installs a panic hook that restores the terminal.
    let mut term = ratatui::try_init().map_err(|e| {
        ratatui::restore();
        Error::new(IO, format!("terminal: {e}"))
    })?;
    let r = event_loop(&mut term, &mut app);
    ratatui::restore();
    r.map_err(|e| Error::new(IO, format!("terminal: {e}")))
}

fn event_loop(term: &mut DefaultTerminal, app: &mut App) -> std::io::Result<()> {
    let mut job = Some(Job::Refresh);
    while !app.quit {
        match job.take().or_else(|| app.missing_detail()) {
            Some(j) => {
                app.message = "working…".into();
                term.draw(|f| draw(f, app))?;
                app.message.clear();
                perform(app, j);
            }
            None => {
                term.draw(|f| draw(f, app))?;
                // Windows reports key releases too.
                if let Event::Key(k) = event::read()?
                    && k.kind == KeyEventKind::Press
                {
                    job = app.key(k);
                }
            }
        }
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq)]
struct Row {
    package: Option<String>,
    version: Option<String>,
    skill: Option<String>,
    state: String,
    ok: bool,
    adopt: Option<String>,
    update: Option<String>,
    /// For a dependency, the packages that require it.
    via: Option<String>,
}

impl Row {
    /// The keys that act on this row, for the actions box.
    fn actions(&self) -> Vec<String> {
        match (&self.package, &self.via) {
            _ if self.state == "not managed" => {
                vec!["m adopt: move this copy aside and install it from a package".into(), "M adopt all with a recorded source".into()]
            }
            (Some(p), Some(via)) => vec![format!("u diff, then update {p}"), format!("a dependency of {via}: remove that to drop it")],
            (Some(p), None) => vec![format!("u diff, then update {p}"), format!("x remove {p}")],
            (None, _) => vec!["none: a project skill, edit it in the repository".into()],
        }
    }
}

#[derive(Debug, PartialEq)]
enum Job {
    Refresh,
    Detail(String),
    /// A command that changes something: show its output, then refresh.
    Run(Vec<String>),
    /// Show `diff <pkg>`, then ask before `update <pkg>`.
    Diff(String),
    Doctor,
    Projects(String),
    /// A query, and the skills.sh choice to save with it (D42).
    Search(String, Option<bool>),
    /// Saves the skills.sh choice through `--global config search.skills-sh`.
    SkillsSh(bool),
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Then {
    Add,
    Adopt,
    Projects,
    Search,
    /// Narrows the list while typing; Enter keeps the filter, Esc clears it.
    Filter,
    Switch,
    /// A picked search result, to edit before `add`.
    Prefill,
}

#[derive(Debug, PartialEq)]
enum Mode {
    List,
    Input {
        prompt: &'static str,
        text: String,
        then: Then,
    },
    Confirm {
        question: String,
        args: Vec<String>,
    },
    /// Whether `search` should also ask skills.sh, before rerunning the query.
    AskSkillsSh(String),
    /// `items` are (value, label).
    Pick {
        title: String,
        items: Vec<(String, String)>,
        sel: usize,
        then: Then,
    },
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum View {
    Info,
    Audit,
    Output,
}

struct Out {
    code: Option<i32>,
    stdout: String,
    stderr: String,
}

struct App {
    exe: PathBuf,
    cwd: PathBuf,
    project: Option<PathBuf>,
    global: bool,
    home: Option<PathBuf>,
    rows: Vec<Row>,
    /// Shows only rows whose skill or package contains it, ignoring case.
    filter: String,
    /// Index into `visible()`.
    sel: usize,
    audit: Vec<Value>,
    /// `repositories` of `status --json`.
    repositories: Vec<Value>,
    /// `skills-sh` of `status --json`: `true`, `false` or `null` (not set).
    skills_sh: Value,
    /// The layer `skills-sh` comes from (`config.toml` or `system config.toml`).
    skills_sh_from: &'static str,
    details: HashMap<String, Vec<String>>,
    view: View,
    output: Vec<String>,
    scroll: u16,
    mode: Mode,
    message: String,
    quit: bool,
}

impl App {
    fn new(exe: PathBuf, cwd: PathBuf, project: Option<PathBuf>, global: bool, home: Option<PathBuf>) -> App {
        App {
            exe,
            cwd,
            project,
            global,
            home,
            rows: Vec::new(),
            filter: String::new(),
            sel: 0,
            audit: Vec::new(),
            repositories: Vec::new(),
            skills_sh: Value::Null,
            skills_sh_from: crate::policy::CONFIG,
            details: HashMap::new(),
            view: View::Info,
            output: Vec::new(),
            scroll: 0,
            mode: Mode::List,
            message: String::new(),
            quit: false,
        }
    }

    /// Base of the relative paths in the JSON documents.
    fn root(&self) -> Option<&Path> {
        if self.global { self.home.as_deref() } else { self.project.as_deref() }
    }

    fn no_manifest(&self) -> bool {
        !self.global && self.project.as_ref().is_none_or(|p| !p.join(crate::manifest::FILE).is_file())
    }

    fn visible(&self) -> Vec<&Row> {
        let f = self.filter.to_lowercase();
        self.rows
            .iter()
            .filter(|r| [&r.skill, &r.package].iter().any(|v| v.as_ref().is_some_and(|v| v.to_lowercase().contains(&f))))
            .collect()
    }

    fn selected(&self) -> Option<&Row> {
        self.visible().get(self.sel).copied()
    }

    fn missing_detail(&self) -> Option<Job> {
        let r = self.selected().filter(|r| r.state != "not managed")?;
        let skill = r.skill.as_ref()?;
        (!self.details.contains_key(skill)).then(|| Job::Detail(skill.clone()))
    }

    fn cli(&self, args: &[String]) -> Out {
        let dir = if self.global { &self.cwd } else { self.project.as_ref().unwrap_or(&self.cwd) };
        spawn(&self.exe, dir, self.global, args)
    }

    fn key(&mut self, k: KeyEvent) -> Option<Job> {
        if k.modifiers.contains(KeyModifiers::CONTROL) && k.code == KeyCode::Char('c') {
            self.quit = true;
            return None;
        }
        match std::mem::replace(&mut self.mode, Mode::List) {
            Mode::List => self.list_key(k.code),
            Mode::Input { then: Then::Filter, mut text, prompt } => {
                match k.code {
                    KeyCode::Esc => text.clear(),
                    KeyCode::Enter => return None,
                    KeyCode::Backspace => {
                        text.pop();
                    }
                    KeyCode::Char(c) => text.push(c),
                    _ => {}
                }
                self.filter = text.clone();
                self.sel = 0;
                self.scroll = 0;
                if k.code != KeyCode::Esc {
                    self.mode = Mode::Input { prompt, text, then: Then::Filter };
                }
                None
            }
            Mode::Input { prompt, mut text, then } => match k.code {
                KeyCode::Esc => None,
                KeyCode::Enter if !text.trim().is_empty() => self.submit(then, text.trim().to_string()),
                code => {
                    match code {
                        KeyCode::Backspace => {
                            text.pop();
                        }
                        KeyCode::Char(c) => text.push(c),
                        _ => {}
                    }
                    self.mode = Mode::Input { prompt, text, then };
                    None
                }
            },
            Mode::Confirm { args, .. } if k.code == KeyCode::Char('y') => Some(Job::Run(args)),
            Mode::Confirm { .. } => {
                self.message = "cancelled".into();
                None
            }
            Mode::AskSkillsSh(q) => match k.code {
                KeyCode::Char('y') => Some(Job::Search(q, Some(true))),
                KeyCode::Char('n') => Some(Job::Search(q, Some(false))),
                _ => {
                    self.message = "cancelled; s asks again".into();
                    None
                }
            },
            Mode::Pick { title, items, mut sel, then } => match k.code {
                KeyCode::Esc => None,
                KeyCode::Enter => match items.get(sel) {
                    Some((v, _)) => self.submit(then, v.clone()),
                    None => None,
                },
                code => {
                    match code {
                        KeyCode::Down | KeyCode::Char('j') => sel = (sel + 1).min(items.len().saturating_sub(1)),
                        KeyCode::Up | KeyCode::Char('k') => sel = sel.saturating_sub(1),
                        _ => {}
                    }
                    self.mode = Mode::Pick { title, items, sel, then };
                    None
                }
            },
        }
    }

    fn list_key(&mut self, code: KeyCode) -> Option<Job> {
        let package = self.selected().and_then(|r| r.package.clone());
        match code {
            KeyCode::Char('q') => self.quit = true,
            KeyCode::Down | KeyCode::Char('j') => {
                self.sel = (self.sel + 1).min(self.visible().len().saturating_sub(1));
                self.scroll = 0;
            }
            KeyCode::Up | KeyCode::Char('k') => {
                self.sel = self.sel.saturating_sub(1);
                self.scroll = 0;
            }
            KeyCode::PageDown => self.scroll = self.scroll.saturating_add(10),
            KeyCode::PageUp => self.scroll = self.scroll.saturating_sub(10),
            KeyCode::Tab => {
                self.view = match self.view {
                    View::Info => View::Audit,
                    View::Audit => View::Output,
                    View::Output => View::Info,
                };
                self.scroll = 0;
            }
            KeyCode::Char('g') => {
                self.global = !self.global;
                self.sel = 0;
                return Some(Job::Refresh);
            }
            KeyCode::Char('r') => return Some(Job::Refresh),
            KeyCode::Char('i') if self.no_manifest() && self.project.is_some() => return Some(Job::Run(args(&["init"]))),
            KeyCode::Char('i') => return Some(Job::Run(args(&["install"]))),
            KeyCode::Char('a') => self.mode = Mode::Input { prompt: "add source", text: String::new(), then: Then::Add },
            KeyCode::Char('M') => {
                let n = self.rows.iter().filter(|r| r.state == "not managed" && r.adopt.is_some()).count();
                if n == 0 {
                    self.message = "no not managed skill has a recorded source".into();
                } else {
                    self.mode = Mode::Confirm {
                        question: format!("adopt {n} skill(s): move the copies aside and install them from their packages? (y/n)"),
                        args: args(&["add", "--adopt", "--all"]),
                    };
                }
            }
            KeyCode::Char('m') => {
                self.mode = match self.selected().filter(|r| r.state == "not managed").map(|r| r.adopt.clone()) {
                    Some(Some(src)) => Mode::Input { prompt: "adopt with add --adopt", text: src, then: Then::Adopt },
                    Some(None) => Mode::Input { prompt: "adopt: no source recorded, type it", text: String::new(), then: Then::Adopt },
                    None => {
                        self.message = "only a not managed skill can be adopted".into();
                        Mode::List
                    }
                }
            }
            KeyCode::Char('u') | KeyCode::Char('x') if package.is_none() => self.message = "not a package".into(),
            KeyCode::Char('x') if self.selected().is_some_and(|r| r.via.is_some()) => {
                self.message = "a dependency: remove the package that requires it".into()
            }
            KeyCode::Char('u') => return package.map(Job::Diff),
            KeyCode::Char('x') => {
                let p = package?;
                self.mode = Mode::Confirm { question: format!("remove {p}? (y/n)"), args: args(&["remove", "--", &p]) };
            }
            KeyCode::Char('o') => return Some(Job::Doctor),
            KeyCode::Char('f') => return Some(Job::Run(args(&["doctor", "--fix"]))),
            KeyCode::Char('/') => self.mode = Mode::Input { prompt: "filter", text: self.filter.clone(), then: Then::Filter },
            KeyCode::Char('s') => {
                self.mode = Mode::Input { prompt: "search Packagist and [repositories]", text: String::new(), then: Then::Search }
            }
            KeyCode::Char('R') => {
                self.output = repository_lines(&self.repositories, &self.skills_sh, self.skills_sh_from);
                self.view = View::Output;
                self.scroll = 0;
            }
            KeyCode::Char('S') => return Some(Job::SkillsSh(self.skills_sh != true)),
            KeyCode::Char('p') => {
                let home = self.home.as_ref().map_or(".".into(), |h| h.display().to_string());
                self.mode = Mode::Input { prompt: "find projects under", text: home, then: Then::Projects };
            }
            _ => {}
        }
        None
    }

    fn submit(&mut self, then: Then, v: String) -> Option<Job> {
        match then {
            Then::Add => Some(Job::Run(args(&["add", "--", &v]))),
            Then::Adopt => Some(Job::Run(args(&["add", "--adopt", "--", &v]))),
            Then::Projects => Some(Job::Projects(v)),
            Then::Search => Some(Job::Search(v, None)),
            Then::Filter => None,
            Then::Prefill => {
                self.mode = Mode::Input { prompt: "add source", text: v, then: Then::Add };
                None
            }
            Then::Switch => {
                self.project = Some(PathBuf::from(v));
                self.global = false;
                self.sel = 0;
                Some(Job::Refresh)
            }
        }
    }

    fn show(&mut self, args: &[String], out: &Out) {
        let code = out.code.map_or("killed".into(), |c| format!("exit {c}"));
        self.output = vec![format!("$ skillcask {}{} ({code})", if self.global { "--global " } else { "" }, args.join(" "))];
        self.output.extend(clean(&out.stdout));
        self.output.extend(clean(&out.stderr));
        self.view = View::Output;
        self.scroll = 0;
    }

    fn refreshed(&mut self, status: &Out, outdated: &Out, audit: &Out) {
        self.details.clear();
        self.audit = json(audit).ok().and_then(|a| a["skills"].as_array().cloned()).unwrap_or_default();
        match json(status) {
            Ok(st) => {
                self.repositories = st["repositories"].as_array().cloned().unwrap_or_default();
                self.skills_sh = st["skills-sh"].clone();
                self.skills_sh_from = crate::policy::outer().map_or(crate::policy::CONFIG, |o| o.label(crate::policy::SKILLS_SH, false));
                let od = json(outdated).unwrap_or_else(|e| {
                    self.message = format!("outdated: {e}");
                    Value::Null
                });
                self.rows = rows(&st, &od);
            }
            Err(e) => {
                self.rows.clear();
                self.message = e;
            }
        }
        self.sel = self.sel.min(self.visible().len().saturating_sub(1));
    }

    fn detail_lines(&self) -> Vec<String> {
        let Some(r) = self.selected() else { return Vec::new() };
        let Some(skill) = &r.skill else {
            return [("package", &r.package), ("version", &r.version), ("state", &Some(r.state.clone()))]
                .iter()
                .filter_map(|(k, v)| v.as_ref().map(|v| format!("{k}: {v}")))
                .collect();
        };
        match self.view {
            // `info` knows only installed packages and project skills.
            View::Info if r.state == "not managed" => vec![
                "not managed by skillcask".into(),
                match &r.adopt {
                    Some(src) => format!("npx skills recorded the source {src}"),
                    None => "no source recorded".into(),
                },
                "press m to adopt: the copy moves to ~/.config/skillcask/adopted/ and the package's skill is installed".into(),
            ],
            View::Info => self.details.get(skill).cloned().unwrap_or_default(),
            View::Audit => audit_lines(&self.audit, skill),
            View::Output => self.output.clone(),
        }
    }
}

/// An `add` that failed on an unmanaged skill in the way asks to rerun it with `--adopt`.
fn adopt_offer(a: &[String], out: &Out) -> Option<Mode> {
    let pkg = a.last().filter(|_| a.first().is_some_and(|c| c == "add") && !a.iter().any(|x| x == "--adopt"))?;
    (out.code != Some(0) && out.stderr.contains(crate::commands::ADOPT_HINT)).then(|| Mode::Confirm {
        question: format!("adopt: move the copy aside and install {pkg}? (y/n)"),
        args: args(&["add", "--adopt", "--", pkg]),
    })
}

fn args(a: &[&str]) -> Vec<String> {
    a.iter().map(|s| s.to_string()).collect()
}

/// The child gets no stdin, so it never prompts; `--` keeps a typed source from being read as a flag.
fn spawn(exe: &Path, dir: &Path, global: bool, args: &[String]) -> Out {
    let mut c = Command::new(exe);
    if global {
        c.arg("--global");
    }
    c.args(args).current_dir(dir).stdin(Stdio::null()).env("NO_COLOR", "1").env("SKILLCASK_AGENT", "0");
    match c.output() {
        Ok(o) => Out {
            code: o.status.code(),
            stdout: String::from_utf8_lossy(&o.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&o.stderr).into_owned(),
        },
        Err(e) => Out { code: None, stdout: String::new(), stderr: format!("{}: {e}", exe.display()) },
    }
}

fn perform(app: &mut App, job: Job) {
    match job {
        Job::Refresh => {
            if app.no_manifest() {
                app.rows.clear();
                app.details.clear();
                app.message = match &app.project {
                    Some(p) => format!("no skills.toml in {}: press i to run init, g for global, p to pick a project", p.display()),
                    None => "no project here: press g for global or p to pick a project".into(),
                };
                return;
            }
            let st = app.cli(&args(&["status", "--json"]));
            let au = app.cli(&args(&["audit", "--json"]));
            let od = app.cli(&args(&["outdated", "--json"]));
            app.refreshed(&st, &od, &au);
        }
        Job::Detail(skill) => {
            let out = app.cli(&args(&["info", "--json", "--", &skill]));
            let lines = detail(&out, app.root());
            app.details.insert(skill, lines);
        }
        Job::Run(a) => {
            let out = app.cli(&a);
            app.show(&a, &out);
            perform(app, Job::Refresh);
            if let Some(m) = adopt_offer(&a, &out) {
                app.mode = m;
            }
        }
        Job::Diff(p) => {
            let a = args(&["diff", "--", &p]);
            let out = app.cli(&a);
            app.show(&a, &out);
            if out.code == Some(0) {
                app.mode = Mode::Confirm { question: format!("update {p}? (y/n)"), args: args(&["update", "--", &p]) };
            }
        }
        Job::Doctor => {
            let a = args(&["doctor", "--json"]);
            let out = app.cli(&a);
            let doc = json(&out).map_or_else(|e| vec![e], |d| value_lines(&d));
            app.show(&a, &Out { stdout: String::new(), ..out });
            app.output.extend(doc);
        }
        Job::Projects(dir) => {
            let out = spawn(&app.exe, &app.cwd, false, &args(&["projects", "--json", "--", &dir]));
            match json(&out) {
                Ok(d) => {
                    let items = list(&d["projects"], |p| Some((p["path"].as_str()?.to_string(), clean(p["path"].as_str()?).join(" "))));
                    app.mode = Mode::Pick { title: format!("projects under {dir}"), items, sel: 0, then: Then::Switch };
                }
                Err(e) => app.message = e,
            }
        }
        Job::SkillsSh(on) => {
            let out = spawn(&app.exe, &app.cwd, true, &args(&["config", "search.skills-sh", if on { "true" } else { "false" }]));
            if out.code == Some(0) {
                app.skills_sh = Value::Bool(on);
            }
            perform(app, Job::Refresh);
            app.output = repository_lines(&app.repositories, &app.skills_sh, app.skills_sh_from);
            app.output.extend(clean(&out.stdout));
            app.output.extend(clean(&out.stderr));
            app.view = View::Output;
            app.scroll = 0;
        }
        Job::Search(q, choice) => {
            let mut a = args(&["search", "--json"]);
            if let Some(on) = choice {
                a.extend(args(&[if on { "--skills-sh" } else { "--no-skills-sh" }, "--remember"]));
            }
            a.extend(args(&["--", &q]));
            match json(&app.cli(&a)) {
                Ok(d) if d["skills-sh"].is_null() && choice.is_none() => app.mode = Mode::AskSkillsSh(q),
                Ok(d) => {
                    let items = list(&d["results"], |r| {
                        let name = r["name"].as_str()?;
                        let installs = r["installs"].as_u64().map_or(String::new(), |i| format!(" {i} installs"));
                        let source = r["source"].as_str().unwrap_or("");
                        let skills = r["skills"].as_u64().filter(|n| *n > 1).map_or(String::new(), |n| format!(" {n} skills"));
                        let req = r["requires"].as_object().map_or(0, |m| m.len());
                        let req = if req > 0 { format!(" +{req} packages") } else { String::new() };
                        let d = r["description"].as_str().unwrap_or("");
                        Some((name.to_string(), format!("{name}  [{source}{installs}{skills}{req}]  {d}")))
                    });
                    if items.is_empty() {
                        let sh = if d["skills-sh"] == true { ", skills.sh" } else { "" };
                        app.message =
                            format!("no skills match {q:?} on Packagist, [repositories]{sh}; GitHub skills: a github:owner/repo/skill");
                    } else {
                        app.mode = Mode::Pick { title: format!("search {q}"), items, sel: 0, then: Then::Prefill };
                    }
                }
                Err(e) => app.message = e,
            }
        }
    }
}

fn list(v: &Value, f: impl Fn(&Value) -> Option<(String, String)>) -> Vec<(String, String)> {
    v.as_array().into_iter().flatten().filter_map(f).collect()
}

/// A command's JSON document, or its error as one line. `status` and `audit` print the
/// document and exit 1 when they find a problem.
fn json(out: &Out) -> std::result::Result<Value, String> {
    serde_json::from_str(&out.stdout).map_err(|_| {
        let err = clean(&out.stderr).into_iter().find(|l| !l.trim().is_empty());
        err.unwrap_or_else(|| format!("exit {}", out.code.unwrap_or(-1)))
    })
}

/// `status --json` entries with the version `update` would lock from `outdated --json`.
fn rows(status: &Value, outdated: &Value) -> Vec<Row> {
    let s = |v: &Value| v.as_str().map(String::from);
    let updates: HashMap<&str, &str> = outdated["packages"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|p| p["within"] != p["locked"])
        .filter_map(|p| Some((p["package"].as_str()?, p["within"].as_str()?)))
        .collect();
    status["entries"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|e| {
            let package = s(&e["package"]);
            let via = e["via"].as_array().map(|v| v.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(", "));
            Row {
                via,
                update: package.as_deref().and_then(|p| updates.get(p)).map(|u| u.to_string()),
                package,
                version: s(&e["version"]),
                skill: s(&e["skill"]),
                state: s(&e["state"]).unwrap_or_default(),
                ok: e["ok"].as_bool().unwrap_or(false),
                adopt: s(&e["adopt"]),
            }
        })
        .collect()
}

fn repository_lines(repos: &[Value], skills_sh: &Value, from: &str) -> Vec<String> {
    let mut out = vec!["repositories (status --json):".to_string()];
    for r in repos {
        let s = |k: &str| r[k].as_str().unwrap_or("").to_string();
        let blocked = if r["allowed"] == false { "  not in policy.allow-sources" } else { "" };
        out.push(format!("  {}  {}  {}{blocked}", s("name"), s("type"), s("url")));
    }
    let sh = if skills_sh.is_boolean() { format!("{skills_sh} ({from})") } else { "not set (off)".into() };
    out.push(format!("search.skills-sh = {sh}; S turns it on or off"));
    out.iter().flat_map(|l| clean(l)).collect()
}

/// Text from a child or a skill with control and invisible characters shown as `<U+XXXX>`,
/// so a skill cannot send escape sequences to the terminal.
fn clean(s: &str) -> Vec<String> {
    s.lines().map(|l| crate::skill::shown(l).replace('\t', "    ")).collect()
}

/// A JSON document as `key: value` lines, arrays one item per line.
fn value_lines(v: &Value) -> Vec<String> {
    let one = |v: &Value| v.as_str().map_or_else(|| v.to_string(), String::from);
    let mut out = Vec::new();
    for (k, v) in v.as_object().into_iter().flatten() {
        match v {
            Value::Null => {}
            Value::Array(a) if a.is_empty() => {}
            Value::Array(a) => {
                out.push(format!("{k}:"));
                out.extend(a.iter().map(|x| format!("  {}", one(x))));
            }
            v => out.push(format!("{k}: {}", one(v))),
        }
    }
    out.iter().flat_map(|l| clean(l)).collect()
}

/// `info --json` and, read-only, the SKILL.md at its `path`.
fn detail(out: &Out, root: Option<&Path>) -> Vec<String> {
    let info = match json(out) {
        Ok(v) => v,
        Err(e) => return vec![e],
    };
    let mut lines = value_lines(&info);
    if let (Some(root), Some(p)) = (root, info["path"].as_str()) {
        lines.push(String::new());
        let mut text = Vec::new();
        match std::fs::File::open(root.join(p).join("SKILL.md")).and_then(|f| f.take(SKILL_MD_MAX).read_to_end(&mut text)) {
            Ok(_) => lines.extend(clean(&String::from_utf8_lossy(&text))),
            Err(e) => lines.push(format!("SKILL.md: {e}")),
        }
    }
    lines
}

fn audit_lines(audit: &[Value], skill: &str) -> Vec<String> {
    let Some(a) = audit.iter().find(|a| a["skill"] == skill) else { return vec!["not in audit".into()] };
    let findings = a["findings"].as_array().map_or(&[][..], |f| f.as_slice());
    let mut out = vec![if findings.is_empty() { "no findings".to_string() } else { "findings:".to_string() }];
    for f in findings {
        let at = f["line"].as_u64().map_or(String::new(), |l| format!(":{l}"));
        out.push(format!(
            "  {} {}{at} {}",
            f["rule"].as_str().unwrap_or(""),
            f["path"].as_str().unwrap_or(""),
            f["message"].as_str().unwrap_or("")
        ));
    }
    let reach: serde_json::Map<String, Value> =
        ["commands", "network", "paths", "env", "scripts"].iter().map(|k| (k.to_string(), a[*k].clone())).collect();
    out.extend(value_lines(&Value::Object(reach)));
    out.iter().flat_map(|l| clean(l)).collect()
}

/// The keys of the current mode.
fn keys(app: &App) -> Vec<&'static str> {
    match &app.mode {
        Mode::Input { then: Then::Filter, .. } => vec!["type to filter", "enter keep", "esc clear"],
        Mode::Input { .. } => vec!["enter submit", "esc cancel", "backspace delete"],
        Mode::Confirm { .. } => vec!["y yes", "any other key no"],
        Mode::AskSkillsSh(_) => vec!["y yes", "n no", "any other key cancel"],
        Mode::Pick { .. } => vec!["↑↓/jk move", "enter choose", "esc cancel"],
        Mode::List => HELP.to_vec(),
    }
}

/// Packs the keys into lines of at most `width` columns, never splitting one key.
fn legend(keys: &[&str], width: u16) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    for k in keys {
        match lines.last_mut() {
            Some(l) if l.chars().count() + 2 + k.chars().count() <= width as usize => {
                l.push_str("  ");
                l.push_str(k);
            }
            _ => lines.push(k.to_string()),
        }
    }
    lines
}

fn draw(f: &mut Frame, app: &App) {
    let legend = legend(&keys(app), f.area().width);
    let [head, body, msg, help] =
        Layout::vertical([Constraint::Length(1), Constraint::Fill(1), Constraint::Length(1), Constraint::Length(legend.len() as u16)])
            .areas(f.area());
    let [left, right] = Layout::horizontal([Constraint::Percentage(45), Constraint::Fill(1)]).areas(body);
    let actions = app.selected().map(|r| (r.skill.as_ref().or(r.package.as_ref()).map_or("-", |s| s.as_str()), r.actions()));
    let [right, actions_area] =
        Layout::vertical([Constraint::Fill(1), Constraint::Length(actions.as_ref().map_or(0, |(_, a)| a.len() as u16 + 2))]).areas(right);
    if let Some((name, lines)) = &actions {
        f.render_widget(
            Paragraph::new(lines.join("\n"))
                .block(Block::bordered().title(clean(&format!("actions: {name}")).join(" ")))
                .wrap(Wrap { trim: false }),
            actions_area,
        );
    }

    let scope = match (&app.project, app.global) {
        (_, true) => "global".to_string(),
        (Some(p), false) => format!("project {}", p.display()),
        (None, false) => "project (none)".to_string(),
    };
    f.render_widget(
        Paragraph::new(clean(&format!("skillcask ui  {scope}")).join(" ")).style(Style::new().add_modifier(Modifier::BOLD)),
        head,
    );

    let highlight = Style::new().add_modifier(Modifier::REVERSED);
    if let Mode::Pick { title, items, sel, .. } = &app.mode {
        let items: Vec<ListItem> = items.iter().map(|(_, l)| ListItem::new(clean(l).join(" "))).collect();
        let list = List::new(items).block(Block::bordered().title(clean(title).join(" "))).highlight_style(highlight);
        f.render_stateful_widget(list, left, &mut ListState::default().with_selected(Some(*sel)));
    } else {
        let items: Vec<ListItem> = app
            .visible()
            .into_iter()
            .map(|r| {
                let name = r.skill.as_ref().or(r.package.as_ref()).map_or("-", |s| s.as_str());
                let span = |s: String, c: Color| Span::styled(clean(&s).join(" "), Style::new().fg(c));
                let state = match (r.ok, r.state.as_str()) {
                    (false, _) => Color::Red,
                    (true, "ok") => Color::Green,
                    _ => Color::Reset,
                };
                let mut line = vec![
                    span(format!("{name:<24} "), if r.ok { Color::Reset } else { Color::Red }),
                    span(format!("{:<10} ", r.version.as_deref().unwrap_or("-")), Color::Cyan),
                    span(r.state.clone(), state),
                ];
                if let Some(u) = &r.update {
                    line.push(span(format!("  ↑ {u}"), Color::Yellow));
                }
                ListItem::new(Line::from(line))
            })
            .collect();
        let list = List::new(items)
            .block(Block::bordered().title(if app.filter.is_empty() {
                "skills".to_string()
            } else {
                clean(&format!("skills matching {:?}  (/ to change, esc in it to clear)", app.filter)).join(" ")
            }))
            .highlight_style(highlight);
        f.render_stateful_widget(list, left, &mut ListState::default().with_selected(Some(app.sel)));
    }

    let title = match app.view {
        View::Info => "info",
        View::Audit => "audit",
        View::Output => "output",
    };
    let lines = if app.view == View::Output { app.output.clone() } else { app.detail_lines() };
    f.render_widget(
        Paragraph::new(lines.join("\n")).block(Block::bordered().title(title)).wrap(Wrap { trim: false }).scroll((app.scroll, 0)),
        right,
    );

    let line = match &app.mode {
        Mode::Input { prompt, text, .. } => format!("{prompt}: {text}_"),
        Mode::Confirm { question, .. } => question.clone(),
        Mode::AskSkillsSh(_) => "also search skills.sh? it receives your queries (y/n)".into(),
        Mode::Pick { .. } | Mode::List => app.message.clone(),
    };
    f.render_widget(Paragraph::new(clean(&line).join(" ")), msg);
    f.render_widget(Paragraph::new(legend.join("\n")).style(Style::new().fg(Color::Cyan)), help);
}

#[cfg(test)]
mod tests {
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;
    use serde_json::json;

    use super::*;

    fn app(rows: Vec<Row>, global: bool) -> App {
        let mut a = App::new("skillcask".into(), ".".into(), Some("/p".into()), global, Some("/h".into()));
        a.rows = rows;
        a
    }

    fn out(stdout: &str) -> Out {
        Out { code: Some(0), stdout: stdout.into(), stderr: String::new() }
    }

    fn press(a: &mut App, c: KeyCode) -> Option<Job> {
        a.key(KeyEvent::new(c, KeyModifiers::NONE))
    }

    fn typed(a: &mut App, s: &str) {
        for c in s.chars() {
            press(a, KeyCode::Char(c));
        }
    }

    fn sample() -> Vec<Row> {
        let st = json!({ "ok": false, "entries": [
            { "package": "acme/one", "version": "1.0.0", "skill": "one", "state": "ok", "ok": true, "adopt": null },
            { "package": "acme/dep", "version": "2.0.0", "skill": "dep", "state": "modified", "ok": false, "adopt": null, "via": ["acme/one"] },
            { "package": null, "version": null, "skill": "mine", "state": "not managed", "ok": true, "adopt": "github:o/r/mine" },
        ]});
        let od = json!({ "packages": [
            { "package": "acme/one", "locked": "1.0.0", "within": "1.1.0", "latest": "2.0.0", "note": null },
            { "package": "acme/dep", "locked": "2.0.0", "within": "2.0.0", "latest": "2.0.0", "note": null },
        ], "behind": [] });
        rows(&st, &od)
    }

    #[test]
    fn rows_join_status_and_outdated() {
        let r = sample();
        assert_eq!(r.len(), 3);
        assert_eq!((r[0].update.as_deref(), r[0].ok), (Some("1.1.0"), true));
        assert_eq!((r[1].package.as_deref(), r[1].update.as_deref(), r[1].ok), (Some("acme/dep"), None, false));
        assert_eq!((r[2].package.as_deref(), r[2].adopt.as_deref()), (None, Some("github:o/r/mine")));
        assert!(rows(&json!({ "entries": [] }), &Value::Null).is_empty());
    }

    #[test]
    fn update_shows_the_diff_first_and_remove_asks() {
        let mut a = app(sample(), false);
        assert_eq!(press(&mut a, KeyCode::Char('u')), Some(Job::Diff("acme/one".into())));
        a.mode = Mode::Confirm { question: "update acme/one? (y/n)".into(), args: args(&["update", "--", "acme/one"]) };
        assert_eq!(press(&mut a, KeyCode::Char('n')), None);
        assert_eq!((&a.mode, a.message.as_str()), (&Mode::List, "cancelled"));

        press(&mut a, KeyCode::Up);
        assert_eq!(press(&mut a, KeyCode::Char('x')), None);
        assert_eq!(press(&mut a, KeyCode::Char('y')), Some(Job::Run(args(&["remove", "--", "acme/one"]))));
        press(&mut a, KeyCode::Down);

        press(&mut a, KeyCode::Down);
        assert_eq!(press(&mut a, KeyCode::Char('u')), None);
        assert_eq!(a.message, "not a package");
    }

    #[test]
    fn the_legend_follows_the_mode_and_wraps_without_splitting_a_key() {
        let mut a = app(sample(), true);
        assert!(keys(&a).contains(&"a add"));
        a.mode = Mode::Confirm { question: String::new(), args: Vec::new() };
        assert_eq!(keys(&a), ["y yes", "any other key no"]);
        assert_eq!(legend(&["ab", "cd", "efg"], 6), ["ab  cd", "efg"]);
        let lines = legend(&HELP, 40);
        assert!(lines.len() > 1 && lines.iter().all(|l| l.chars().count() <= 40));
        assert_eq!(lines.join("  "), HELP.join("  "));
    }

    #[test]
    fn an_unmanaged_skill_explains_adopt_instead_of_running_info() {
        // Regression: info failed with "no installed skill" for every not managed row.
        let mut a = app(sample(), true);
        a.sel = 2;
        assert_eq!(a.missing_detail(), None);
        let lines = a.detail_lines();
        assert!(lines.iter().any(|l| l.contains("github:o/r/mine")) && lines.iter().any(|l| l.starts_with("press m")), "{lines:?}");
    }

    #[test]
    fn a_failed_add_on_an_unmanaged_skill_offers_adopt() {
        let failed = |stderr: &str| Out { code: Some(1), stdout: String::new(), stderr: stderr.into() };
        let err = failed(&format!(
            "error: ~/.agents/skills/two exists and is not managed by skillcask, but acme/two provides a skill with that name{}",
            crate::commands::ADOPT_HINT
        ));
        let offer = adopt_offer(&args(&["add", "--", "acme/two"]), &err);
        assert!(matches!(&offer, Some(Mode::Confirm { args: a, .. }) if *a == args(&["add", "--adopt", "--", "acme/two"])));
        assert!(adopt_offer(&args(&["add", "--adopt", "--", "acme/two"]), &err).is_none());
        assert!(adopt_offer(&args(&["add", "--", "acme/two"]), &failed("error: other")).is_none());
    }

    #[test]
    fn add_prompts_and_adopt_is_prefilled_for_unmanaged_skills() {
        let mut a = app(sample(), true);
        press(&mut a, KeyCode::Char('a'));
        typed(&mut a, "acme/twx");
        press(&mut a, KeyCode::Backspace);
        typed(&mut a, "o");
        assert_eq!(press(&mut a, KeyCode::Enter), Some(Job::Run(args(&["add", "--", "acme/two"]))));

        a.sel = 2;
        press(&mut a, KeyCode::Char('m'));
        assert!(matches!(&a.mode, Mode::Input { text, then: Then::Adopt, .. } if text == "github:o/r/mine"));
        assert_eq!(press(&mut a, KeyCode::Enter), Some(Job::Run(args(&["add", "--adopt", "--", "github:o/r/mine"]))));

        press(&mut a, KeyCode::Char('m'));
        assert_eq!(press(&mut a, KeyCode::Esc), None);

        press(&mut a, KeyCode::Char('M'));
        assert!(matches!(&a.mode, Mode::Confirm { question, .. } if question.starts_with("adopt 1 skill(s)")));
        assert_eq!(press(&mut a, KeyCode::Char('y')), Some(Job::Run(args(&["add", "--adopt", "--all"]))));

        // Regression: an unmanaged skill without a recorded source got a plain add prompt.
        a.rows[2].adopt = None;
        press(&mut a, KeyCode::Char('m'));
        assert!(matches!(&a.mode, Mode::Input { text, then: Then::Adopt, .. } if text.is_empty()));
        typed(&mut a, "github:o/r/mine");
        assert_eq!(press(&mut a, KeyCode::Enter), Some(Job::Run(args(&["add", "--adopt", "--", "github:o/r/mine"]))));
        assert_eq!(a.mode, Mode::List);

        a.sel = 0;
        press(&mut a, KeyCode::Char('m'));
        assert_eq!((&a.mode, a.message.as_str()), (&Mode::List, "only a not managed skill can be adopted"));
    }

    #[test]
    fn slash_filters_the_list_and_s_searches_the_registries() {
        // Regression: `/` searched Packagist, which looked like a filter of the list that found nothing.
        let mut a = app(sample(), true);
        press(&mut a, KeyCode::Char('/'));
        typed(&mut a, "MI");
        assert_eq!(a.visible().iter().map(|r| r.skill.as_deref()).collect::<Vec<_>>(), [Some("mine")]);
        assert_eq!(a.selected().and_then(|r| r.skill.as_deref()), Some("mine"));
        assert_eq!(press(&mut a, KeyCode::Enter), None);
        assert_eq!((&a.mode, a.filter.as_str()), (&Mode::List, "MI"));
        press(&mut a, KeyCode::Char('/'));
        press(&mut a, KeyCode::Esc);
        assert_eq!((&a.mode, a.visible().len()), (&Mode::List, 3));

        press(&mut a, KeyCode::Char('s'));
        typed(&mut a, "jira");
        assert_eq!(press(&mut a, KeyCode::Enter), Some(Job::Search("jira".into(), None)));
    }

    #[test]
    fn search_asks_about_skills_sh_once_and_r_lists_repositories() {
        let mut a = app(sample(), true);
        a.mode = Mode::AskSkillsSh("jira".into());
        assert_eq!(press(&mut a, KeyCode::Char('y')), Some(Job::Search("jira".into(), Some(true))));
        a.mode = Mode::AskSkillsSh("jira".into());
        assert_eq!(press(&mut a, KeyCode::Char('n')), Some(Job::Search("jira".into(), Some(false))));
        a.mode = Mode::AskSkillsSh("jira".into());
        assert_eq!((press(&mut a, KeyCode::Esc), &a.mode), (None, &Mode::List));

        a.mode = Mode::Pick { title: "t".into(), items: vec![("github:o/r/s".into(), "x".into())], sel: 0, then: Then::Prefill };
        press(&mut a, KeyCode::Enter);
        assert!(matches!(&a.mode, Mode::Input { text, then: Then::Add, .. } if text == "github:o/r/s"));
        a.mode = Mode::List;

        a.repositories = vec![
            json!({ "name": "packagist", "type": "composer", "url": "https://repo.packagist.org/", "allowed": true }),
            json!({ "name": "github", "type": "github", "url": "https://api.github.com/", "allowed": false }),
        ];
        press(&mut a, KeyCode::Char('R'));
        assert_eq!(a.view, View::Output);
        assert_eq!(
            a.output[1..],
            [
                "  packagist  composer  https://repo.packagist.org/",
                "  github  github  https://api.github.com/  not in policy.allow-sources",
                "search.skills-sh = not set (off); S turns it on or off",
            ]
        );
        assert_eq!(press(&mut a, KeyCode::Char('S')), Some(Job::SkillsSh(true)));
        a.skills_sh = json!(true);
        assert_eq!(press(&mut a, KeyCode::Char('S')), Some(Job::SkillsSh(false)));
        press(&mut a, KeyCode::Char('R'));
        assert_eq!(a.output[3], "search.skills-sh = true (config.toml); S turns it on or off");
        a.skills_sh_from = crate::policy::SYSTEM;
        press(&mut a, KeyCode::Char('R'));
        assert_eq!(a.output[3], "search.skills-sh = true (system config.toml); S turns it on or off");
    }

    #[test]
    fn the_actions_box_lists_only_what_the_selected_row_allows() {
        let mut a = app(sample(), true);
        assert_eq!(a.rows[0].actions(), ["u diff, then update acme/one", "x remove acme/one"]);
        assert_eq!(a.rows[1].via.as_deref(), Some("acme/one"));
        assert!(a.rows[1].actions()[1].contains("dependency of acme/one"));
        assert!(a.rows[2].actions()[0].starts_with("m adopt"));
        a.sel = 1;
        press(&mut a, KeyCode::Char('x'));
        assert_eq!((&a.mode, a.message.as_str()), (&Mode::List, "a dependency: remove the package that requires it"));
    }

    #[test]
    fn scope_toggles_and_a_picked_project_becomes_the_scope() {
        let mut a = app(sample(), false);
        assert_eq!(press(&mut a, KeyCode::Char('g')), Some(Job::Refresh));
        assert!(a.global);
        assert_eq!(a.root(), Some(Path::new("/h")));

        press(&mut a, KeyCode::Char('p'));
        assert!(matches!(&a.mode, Mode::Input { text, .. } if text == "/h"));
        assert_eq!(press(&mut a, KeyCode::Enter), Some(Job::Projects("/h".into())));
        a.mode = Mode::Pick {
            title: "t".into(),
            items: vec![("/a".into(), "/a".into()), ("/b".into(), "/b".into())],
            sel: 0,
            then: Then::Switch,
        };
        press(&mut a, KeyCode::Down);
        assert_eq!(press(&mut a, KeyCode::Enter), Some(Job::Refresh));
        assert_eq!((a.global, a.project.as_deref()), (false, Some(Path::new("/b"))));
    }

    #[test]
    fn i_runs_init_without_a_manifest() {
        let tmp = tempfile::tempdir().unwrap();
        let mut a = app(Vec::new(), false);
        a.project = Some(tmp.path().to_path_buf());
        assert_eq!(press(&mut a, KeyCode::Char('i')), Some(Job::Run(args(&["init"]))));
        std::fs::write(tmp.path().join("skills.toml"), "").unwrap();
        assert_eq!(press(&mut a, KeyCode::Char('i')), Some(Job::Run(args(&["install"]))));
        assert_eq!(press(&mut a, KeyCode::Char('q')), None);
        assert!(a.quit);
    }

    #[test]
    fn skill_text_cannot_drive_the_terminal() {
        assert_eq!(clean("a\x1b]52;c;eA==\x07b\r\n\u{200b}c\td"), ["a<U+001B>]52;c;eA==<U+0007>b", "<U+200B>c    d"]);

        let tmp = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(tmp.path().join(".agents/skills/one")).unwrap();
        std::fs::write(tmp.path().join(".agents/skills/one/SKILL.md"), "# One\n\x1b[2Jboom").unwrap();
        let info = out(r#"{"skill":"one","kind":"package","package":"acme/one","path":".agents/skills/one","why":["acme/one: x"]}"#);
        let lines = detail(&info, Some(tmp.path()));
        assert_eq!(
            lines,
            [
                "kind: package",
                "package: acme/one",
                "path: .agents/skills/one",
                "skill: one",
                "why:",
                "  acme/one: x",
                "",
                "# One",
                "<U+001B>[2Jboom"
            ]
        );
        let err = Out { code: Some(1), stdout: String::new(), stderr: "error: no installed skill \"x\"\n".into() };
        assert_eq!(detail(&err, None), ["error: no installed skill \"x\""]);
    }

    #[test]
    fn audit_lists_findings_and_reach_of_the_skill() {
        let audit = vec![
            json!({ "skill": "one", "findings": [{ "rule": "risky-pattern", "path": ".agents/skills/one/SKILL.md", "line": 3, "message": "curl piped into sh" }],
            "commands": ["curl"], "network": [], "paths": [], "env": ["HOME"], "scripts": [] }),
        ];
        assert_eq!(
            audit_lines(&audit, "one"),
            ["findings:", "  risky-pattern .agents/skills/one/SKILL.md:3 curl piped into sh", "commands:", "  curl", "env:", "  HOME"]
        );
        assert_eq!(audit_lines(&audit, "two"), ["not in audit"]);
    }

    #[test]
    fn draws_rows_detail_and_help() {
        let mut a = app(sample(), false);
        a.details.insert("one".into(), vec!["skill: one".into()]);
        a.message = "bad\x1b[31m".into();
        let mut t = Terminal::new(TestBackend::new(160, 12)).unwrap();
        t.draw(|f| draw(f, &a)).unwrap();
        let screen: String = t.backend().buffer().content().iter().map(|c| c.symbol()).collect();
        assert!(screen.contains("project /p"), "{screen}");
        assert!(screen.contains("one                      1.0.0      ok  ↑ 1.1.0"), "{screen}");
        assert!(screen.contains("skill: one"), "{screen}");
        assert!(screen.contains("bad<U+001B>[31m"), "{screen}");
        assert!(screen.contains("q quit"), "{screen}");
    }
}
