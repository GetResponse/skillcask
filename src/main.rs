#![forbid(unsafe_code)]

mod archive;
mod commands;
mod config;
mod credential;
mod deps;
mod diff;
mod error;
mod git;
mod github;
mod http;
mod lock;
mod manifest;
mod policy;
mod project;
mod publish;
mod registry;
mod scope;
mod self_check;
mod self_update;
mod skill;
mod tui;
mod ui;
mod version;

use std::ffi::OsString;
use std::io::IsTerminal;
use std::path::PathBuf;

use clap::{Parser, Subcommand};

use crate::archive::Limits;
use crate::commands::Ctx;
use crate::error::{Error, MANIFEST};
use crate::scope::Scope;

const VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), " (", env!("SKILLCASK_COMMIT"), ")");

/// A lockfile-first package manager for AI agent skills.
#[derive(Parser)]
#[command(name = "skillcask", version = VERSION)]
struct Cli {
    /// Print every HTTP request (credentials are never printed).
    #[arg(short, long, global = true)]
    verbose: bool,
    /// Manage personal skills in ~/.agents/skills instead of the project's.
    #[arg(short, long, global = true)]
    global: bool,
    /// Terse output for coding agents: no colour, no padding, problems only. Also SKILLCASK_AGENT=1;
    /// detected from AI_AGENT or CLAUDECODE unless SKILLCASK_AGENT=0.
    #[arg(long, global = true)]
    agent: bool,
    /// Maximum download size, e.g. 50M.
    #[arg(long, global = true, value_parser = parse_size)]
    max_download: Option<u64>,
    /// Maximum unpacked size of one archive, e.g. 100M.
    #[arg(long, global = true, value_parser = parse_size)]
    max_unpacked: Option<u64>,
    /// Maximum number of files in one archive.
    #[arg(long, global = true)]
    max_files: Option<usize>,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum AuthCmd {
    /// Store a token for a host; asked without echo, or read from stdin when piped.
    Set {
        /// host or host:port
        host: String,
        /// PRIVATE-TOKEN sends a GitLab PRIVATE-TOKEN header, oauth2 a Bearer token, any other
        /// name HTTP Basic.
        #[arg(long, default_value = credential::PRIVATE_TOKEN)]
        username: String,
    },
    /// Remove the stored token of a host.
    Remove {
        host: String,
        #[arg(long, default_value = credential::PRIVATE_TOKEN)]
        username: String,
    },
}

#[derive(Subcommand)]
enum Cmd {
    /// Create skills.toml with defaults.
    Init,
    /// Resolve a package, add it to skills.toml and skills.lock, install it.
    Add {
        /// vendor/name[@constraint], github:owner/repo[/skill][@version-or-ref], or
        /// git:https://host/owner/repo.git[@version-or-ref]
        #[arg(required_unless_present = "all")]
        package: Option<String>,
        /// Repository name from [repositories].
        #[arg(long)]
        repository: Option<String>,
        /// With --global: move a skill of the same name that skillcask does not manage to
        /// ~/.config/skillcask/adopted/ and install the package's in its place.
        #[arg(long)]
        adopt: bool,
        /// With --adopt: adopt every skill not managed whose source `npx skills` recorded.
        #[arg(long, requires = "adopt", conflicts_with_all = ["package", "repository"])]
        all: bool,
    },
    /// Remove packages from skills.toml and skills.lock, with their files and links.
    Remove {
        #[arg(required = true)]
        packages: Vec<String>,
    },
    /// Install exactly what skills.lock pins.
    Install {
        /// Fail instead of resolving when skills.lock does not match skills.toml (implied by CI).
        #[arg(long)]
        frozen: bool,
    },
    /// Re-resolve within constraints and rewrite skills.lock.
    Update {
        packages: Vec<String>,
        /// Print a unified diff of each updated or added package's skill files; it does not ask
        /// for confirmation (review with `skillcask diff` first).
        #[arg(long)]
        diff: bool,
    },
    /// Show newer versions per package.
    Outdated {
        /// Exit 1 when `update` would lock a newer version within a package's constraint.
        #[arg(long)]
        strict: bool,
        /// Print one JSON document instead of text (D32).
        #[arg(long)]
        json: bool,
    },
    /// Unified diff of skill files from the locked version to the one `update` would lock.
    Diff {
        /// One package (also a dependency); default: every entry of skills.toml with a newer version.
        package: Option<String>,
        /// Compare with the newest version matching this instead, cooldown not applied.
        #[arg(long, conflicts_with = "from")]
        to: Option<String>,
        /// Compare skills.lock with this older lock instead (`-`: stdin), e.g. the target branch's in a review.
        #[arg(long)]
        from: Option<std::path::PathBuf>,
    },
    /// A package's skills, versions, description, license and requirements; for an installed
    /// skill name, which package and skills.toml entry install it.
    Info {
        /// vendor/name[@constraint], github:owner/repo[@version-or-ref], or a skill name
        target: String,
        /// Print one JSON document instead of text (D32).
        #[arg(long)]
        json: bool,
    },
    /// Compare skills.toml, skills.lock and installed files; exit 1 on any mismatch.
    Status {
        /// Print one JSON document instead of text (D32).
        #[arg(long)]
        json: bool,
    },
    /// Check links, the gitignore block and installed files.
    Doctor {
        /// Repair links, the git index and the gitignore block (never downloads).
        #[arg(long)]
        fix: bool,
        /// Print one JSON document instead of text (D32).
        #[arg(long)]
        json: bool,
    },
    /// List what installed skills reach (commands, network, paths, env, scripts) and flag modified
    /// files, risky lines and invisible characters; exit 1 on any finding.
    Audit {
        /// Print one JSON document instead of text (D32).
        #[arg(long, conflicts_with = "sarif")]
        json: bool,
        /// Print a SARIF 2.1.0 log for code scanning.
        #[arg(long)]
        sarif: bool,
        /// Also check locked packages for published security advisories and abandoned packages (network, D55).
        #[arg(long)]
        advisories: bool,
    },
    /// Search for skill packages; with skills.sh on, also the GitHub skills it lists.
    Search {
        /// Optional with --remember, which then only saves the choice.
        #[arg(required_unless_present = "remember")]
        query: Option<String>,
        /// Print one JSON document instead of text (D32).
        #[arg(long)]
        json: bool,
        /// Also search skills.sh (it receives the query) for this run.
        #[arg(long, conflicts_with = "no_skills_sh")]
        skills_sh: bool,
        /// Do not search skills.sh for this run.
        #[arg(long)]
        no_skills_sh: bool,
        /// Save --skills-sh or --no-skills-sh as [search] skills-sh in config.toml.
        #[arg(long)]
        remember: bool,
    },
    /// Show or change settings with their origin: [policy] and [agents] targets of skills.toml, or
    /// with --global of config.toml, which also has policy.enforce and search.skills-sh.
    Config {
        /// A key such as policy.min-release-age, or `edit` to open the file in $VISUAL or $EDITOR;
        /// none lists every setting.
        key: Option<String>,
        /// The value to set; a list takes one argument per entry.
        #[arg(conflicts_with = "unset")]
        value: Vec<String>,
        /// Remove the key from the file.
        #[arg(long, requires = "key")]
        unset: bool,
        /// Print one JSON document instead of text (D32).
        #[arg(long, conflicts_with_all = ["value", "unset"])]
        json: bool,
    },
    /// Keep a registry token in git's credential helper (Keychain, Credential Manager, libsecret).
    #[command(subcommand)]
    Auth(AuthCmd),
    /// Build a static Composer repository from SKILL.md files in a monorepo.
    Publish {
        #[arg(long)]
        vendor: String,
        /// Public https:// URL the output directory will be served from.
        #[arg(long)]
        base_url: Option<String>,
        /// Dist URL template with {vendor}, {name} and {version}.
        #[arg(long)]
        dist_url: Option<String>,
        /// Write all packages into packages.json instead of metadata-url and p2/.
        #[arg(long)]
        inline: bool,
        #[arg(long)]
        out: PathBuf,
        paths: Vec<PathBuf>,
    },
    /// Check skills against the Agent Skills SKILL.md spec; warn about invisible Unicode.
    Validate {
        /// Skill directories, or directories to search for SKILL.md (default: the current one).
        paths: Vec<PathBuf>,
    },
    /// List directories that hold skills.toml under the given ones (default: the current one),
    /// skipping hidden directories, node_modules, vendor, target and Library.
    Projects {
        dirs: Vec<PathBuf>,
        /// Print one JSON document instead of text (D32).
        #[arg(long)]
        json: bool,
    },
    /// Browse, add, update and remove skills in a terminal UI; it runs this binary for every step.
    Ui,
    /// Open the macOS app (brew install getresponse/tap/skillcask-app).
    App,
    /// Say whether a newer skillcask is released: one anonymous request for the tap's cask file,
    /// only when run; writes nothing.
    SelfCheck {
        /// Print one JSON document instead of text (D32).
        #[arg(long)]
        json: bool,
    },
    /// Update skillcask: rerun the release's installer when it installed this binary (Unix),
    /// else name the command for Homebrew, npm, cargo or the app.
    SelfUpdate {
        /// Print what would run, run nothing.
        #[arg(long)]
        dry_run: bool,
    },
    /// Any other command runs `skillcask-<command>` from PATH, like git and cargo plugins.
    #[command(external_subcommand)]
    External(Vec<OsString>),
}

fn parse_size(s: &str) -> Result<u64, String> {
    let s = s.trim();
    let (num, mult) = match s.char_indices().last() {
        Some((i, 'K' | 'k')) => (&s[..i], 1 << 10),
        Some((i, 'M' | 'm')) => (&s[..i], 1 << 20),
        Some((i, 'G' | 'g')) => (&s[..i], 1 << 30),
        _ => (s, 1),
    };
    num.parse::<u64>().ok().and_then(|n| n.checked_mul(mult)).ok_or_else(|| format!("invalid size {s:?}, use e.g. 50M"))
}

fn ci() -> bool {
    std::env::var("CI").is_ok_and(|v| !v.is_empty() && v != "0" && !v.eq_ignore_ascii_case("false"))
}

fn run(cli: Cli) -> Result<(), Error> {
    let d = Limits::default();
    let limits = Limits {
        download: cli.max_download.unwrap_or(d.download),
        unpacked: cli.max_unpacked.unwrap_or(d.unpacked),
        files: cli.max_files.unwrap_or(d.files),
    };
    if cli.global
        && matches!(cli.cmd, Cmd::External(_) | Cmd::Publish { .. } | Cmd::Auth(_) | Cmd::Validate { .. } | Cmd::Projects { .. } | Cmd::App)
    {
        return Err(Error::new(MANIFEST, "--global does not apply to this command"));
    }
    if let Cmd::External(args) = &cli.cmd {
        return plugin(args);
    }
    if let Cmd::Auth(a) = &cli.cmd {
        return auth(a);
    }
    if let Cmd::Validate { paths } = &cli.cmd {
        return publish::validate(paths);
    }
    if let Cmd::Projects { dirs, json } = &cli.cmd {
        return commands::projects(dirs, *json);
    }
    if let Cmd::Ui = cli.cmd {
        return tui::run(cli.global);
    }
    if let Cmd::App = cli.cmd {
        return app();
    }
    // Needs no project; --global changes nothing here.
    if let Cmd::SelfCheck { json } = cli.cmd {
        return self_check::run(cli.verbose, json);
    }
    if let Cmd::SelfUpdate { dry_run } = cli.cmd {
        return self_update::run(cli.verbose, dry_run);
    }
    let scope = if cli.global {
        Scope::global()?
    } else {
        Scope::project(match cli.cmd {
            Cmd::Init => {
                let cwd = std::env::current_dir()?;
                project::check_root(&cwd)?;
                cwd
            }
            Cmd::Publish { .. } => std::env::current_dir()?,
            _ => project::find_root()?,
        })
    };
    let interactive = !ci() && std::io::stdin().is_terminal() && std::io::stderr().is_terminal();
    let mut ctx = Ctx::new(scope, cli.verbose, limits, interactive);
    ctx.read_only = matches!(cli.cmd, Cmd::Info { .. } | Cmd::Diff { .. });
    match cli.cmd {
        Cmd::Init => commands::init(&ctx),
        Cmd::Add { package, repository, adopt, .. } => {
            ctx.adopt = adopt;
            match package {
                Some(p) => commands::add(&ctx, &p, repository),
                None => commands::adopt_all(&ctx),
            }
        }
        Cmd::Remove { packages } => commands::remove(&ctx, &packages),
        Cmd::Install { frozen } => commands::install(&ctx, frozen || ci()),
        Cmd::Update { packages, diff } => commands::update(&ctx, &packages, diff),
        Cmd::Outdated { strict, json } => commands::outdated(&ctx, strict, json),
        Cmd::Diff { package, to, from } => match from {
            Some(base) => commands::diff_from(&ctx, &base, package.as_deref()),
            None => commands::diff(&ctx, package.as_deref(), to.as_deref()),
        },
        Cmd::Info { target, json } => commands::info(&ctx, &target, json),
        Cmd::Status { json } => commands::status(&ctx, json),
        Cmd::Doctor { fix, json } => commands::doctor(&ctx, fix, json),
        Cmd::Audit { json, sarif, advisories } => commands::audit(&ctx, json, sarif, advisories),
        Cmd::Search { query, json, skills_sh, no_skills_sh, remember } => {
            let choice = (skills_sh || no_skills_sh).then_some(skills_sh);
            if remember && choice.is_none() {
                return Err(Error::new(MANIFEST, "--remember needs --skills-sh or --no-skills-sh"));
            }
            commands::search(&ctx, query.as_deref(), json, choice, remember)
        }
        Cmd::Config { key, value, unset, json } => config::run(&ctx.s, key.as_deref(), &value, unset, json),
        Cmd::External(_)
        | Cmd::Auth(_)
        | Cmd::Validate { .. }
        | Cmd::Projects { .. }
        | Cmd::Ui
        | Cmd::App
        | Cmd::SelfCheck { .. }
        | Cmd::SelfUpdate { .. } => {
            unreachable!("handled above")
        }
        Cmd::Publish { vendor, base_url, dist_url, inline, out, paths } => {
            if vendor.is_empty() {
                return Err(Error::new(MANIFEST, "--vendor must not be empty"));
            }
            publish::publish(&publish::PublishArgs { vendor, base_url, dist_url, inline, out, paths })
        }
    }
}

fn auth(cmd: &AuthCmd) -> Result<(), Error> {
    let (AuthCmd::Set { host, username } | AuthCmd::Remove { host, username }) = cmd;
    // Accepts a URL too; git's helpers key credentials by host and port.
    let url = url::Url::parse(host).or_else(|_| url::Url::parse(&format!("https://{host}")));
    let Some(key) = url
        .ok()
        .filter(|u| u.scheme() == "https")
        .and_then(|u| Some(u.host_str()?.to_string() + &u.port().map(|p| format!(":{p}")).unwrap_or_default()))
    else {
        return Err(Error::new(MANIFEST, format!("invalid host {host:?}")));
    };
    match cmd {
        AuthCmd::Set { .. } => {
            let piped = !std::io::stdin().is_terminal();
            let token = if piped { Some(std::io::read_to_string(std::io::stdin())?.trim().to_string()) } else { None };
            let (chars, helpers) = credential::store(&key, username, token.as_deref())?;
            ui::done("stored", format!("a {chars}-character token for {key} with git's credential helper ({helpers})"));
        }
        AuthCmd::Remove { .. } => credential::remove(&key, username)?,
    }
    Ok(())
}

/// Opens the macOS app through LaunchServices, wherever it is installed (D50).
fn app() -> Result<(), Error> {
    if !cfg!(target_os = "macos") {
        return Err(Error::new(MANIFEST, "skillcask app is a macOS app").hint("use skillcask ui on this system"));
    }
    let out = std::process::Command::new("/usr/bin/open")
        .args(["-b", "io.github.puniserv.skillcask"])
        .stdin(std::process::Stdio::null())
        .output()
        .map_err(|e| Error::new(error::IO, format!("open: {e}")))?;
    if !out.status.success() {
        return Err(Error::new(MANIFEST, "Skillcask.app is not installed").hint(
            "brew install getresponse/tap/skillcask getresponse/tap/skillcask-app, or unzip Skillcask-<version>-macos-universal.zip from a release into /Applications",
        ));
    }
    Ok(())
}

/// Runs a user-installed `skillcask-<name>` executable. Packages never provide these.
fn plugin(args: &[OsString]) -> Result<(), Error> {
    let name = args[0].to_string_lossy();
    // A separator would make Command run a path relative to the cwd instead of searching PATH.
    if name.is_empty() || name.contains(['/', '\\']) {
        return Err(Error::new(MANIFEST, format!("unknown command {name:?}")));
    }
    let exe = format!("skillcask-{name}");
    let status = std::process::Command::new(&exe).args(&args[1..]).status().map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            Error::new(MANIFEST, format!("unknown command {name:?} (no {exe} on PATH)"))
        } else {
            Error::new(error::IO, format!("{exe}: {e}"))
        }
    })?;
    #[cfg(unix)]
    if let Some(sig) = std::os::unix::process::ExitStatusExt::signal(&status) {
        std::process::exit(128 + sig);
    }
    std::process::exit(status.code().unwrap_or(1));
}

fn main() {
    // clap exits 2 on usage errors, which here means authentication.
    let cli = Cli::try_parse().unwrap_or_else(|e| {
        let _ = e.print();
        std::process::exit(if e.use_stderr() { MANIFEST.into() } else { 0 });
    });
    ui::init(cli.agent);
    let r = run(cli);
    project::end_runs();
    if let Err(e) = r {
        ui::error(&e.msg, e.hint.as_deref());
        std::process::exit(e.code.into());
    }
}
