//! `self-update` (D52): rerun the release's shell installer for an installer-script install on
//! Unix; for every other install, name the one command that updates it.

use std::path::{Path, PathBuf};

use crate::error::{Error, MANIFEST, Result};
use crate::self_check::{RELEASES, RUNNING, is_newer, latest_release};

#[derive(Debug, PartialEq)]
enum Method {
    /// The CLI inside `Skillcask.app`; `true` when Homebrew's cask installed the app.
    App(bool),
    Homebrew,
    Npm,
    Bun,
    Cargo,
    /// dist's shell or PowerShell installer, with the receipt's `install_prefix`.
    Installer(PathBuf),
    Unknown,
}

const CASKROOMS: [&str; 2] = ["/opt/homebrew/Caskroom/skillcask-app", "/usr/local/Caskroom/skillcask-app"];

pub fn run(verbose: bool, dry_run: bool) -> Result<()> {
    let Some(latest) = latest_release(verbose)? else {
        return Err(Error::new(MANIFEST, "the latest skillcask version is unknown").hint(format!("see {RELEASES}")));
    };
    if !is_newer(&latest) {
        println!("skillcask {RUNNING} is the latest");
        return Ok(());
    }
    let exe = std::fs::canonicalize(std::env::current_exe()?)?;
    let method = detect(&exe, cargo_home().as_deref(), receipt_dir().as_deref());
    let off = std::env::var_os("SKILLCASK_SELF_UPDATE").is_some_and(|v| v == "0");
    #[cfg(unix)]
    if let Method::Installer(prefix) = &method
        && !off
    {
        return installer(verbose, &latest, prefix, dry_run);
    }
    let _ = dry_run;
    let Some((how, command)) = advice(&method, &latest, cfg!(windows)) else {
        return Err(Error::new(MANIFEST, format!("skillcask {RUNNING} -> {latest}: cannot tell how skillcask was installed"))
            .hint(format!("update it the way you installed it; see {RELEASES}/tag/v{latest}")));
    };
    let why = if off && matches!(method, Method::Installer(_)) { " (SKILLCASK_SELF_UPDATE=0)" } else { "" };
    Err(Error::new(MANIFEST, format!("skillcask {RUNNING} -> {latest}: installed with {how}{why}; update with:")).hint(command))
}

/// One pasteable command per method; `None` when the method is unknown.
fn advice(method: &Method, latest: &str, windows: bool) -> Option<(&'static str, String)> {
    let download = format!("{RELEASES}/download/v{latest}");
    Some(match method {
        Method::Installer(_) if windows => {
            ("the PowerShell installer", format!("powershell -ExecutionPolicy Bypass -c \"irm {download}/skillcask-installer.ps1 | iex\""))
        }
        Method::Installer(_) => {
            ("the shell installer", format!("curl --proto '=https' --tlsv1.2 -LsSf {download}/skillcask-installer.sh | sh"))
        }
        Method::App(true) => ("the Homebrew cask skillcask-app", "brew update && brew upgrade skillcask skillcask-app".into()),
        Method::App(false) => (
            "the macOS app",
            format!("curl --proto '=https' --tlsv1.2 -LsSf {download}/skillcask-app-installer.sh | SKILLCASK_VERSION={latest} sh"),
        ),
        Method::Homebrew => ("Homebrew", "brew update && brew upgrade skillcask".into()),
        Method::Npm => ("npm", "npm install -g skillcask@latest".into()),
        Method::Bun => ("bun", "bun add -g skillcask@latest".into()),
        Method::Cargo => ("cargo install", "cargo install --locked skillcask".into()),
        Method::Unknown => return None,
    })
}

/// `$CARGO_HOME`, else `~/.cargo`: where both `cargo install` and dist's installer put the binary.
fn cargo_home() -> Option<PathBuf> {
    std::env::var_os("CARGO_HOME").filter(|v| !v.is_empty()).map(PathBuf::from).or_else(|| crate::scope::home().map(|h| h.join(".cargo")))
}

/// Where dist's installer writes `skillcask-receipt.json`: not `SKILLCASK_HOME`, which dist does
/// not know.
fn receipt_dir() -> Option<PathBuf> {
    let var = |k: &str| std::env::var_os(k).filter(|v| !v.is_empty()).map(PathBuf::from);
    if cfg!(windows) {
        return var("LOCALAPPDATA").map(|d| d.join("skillcask"));
    }
    var("XDG_CONFIG_HOME").or_else(|| crate::scope::home().map(|h| h.join(".config"))).map(|d| d.join("skillcask"))
}

/// First match wins. `cargo install` comes before the receipt because both write
/// `<cargo_home>/bin`, and a later `cargo install` leaves the installer's receipt behind.
fn detect(exe: &Path, cargo_home: Option<&Path>, receipt_dir: Option<&Path>) -> Method {
    let path = exe.to_string_lossy().replace('\\', "/");
    if path.contains(".app/Contents/Helpers/") {
        return Method::App(CASKROOMS.iter().any(|c| Path::new(c).is_dir()));
    }
    if path.contains("/Cellar/") {
        return Method::Homebrew;
    }
    if path.contains("/.bun/") {
        return Method::Bun;
    }
    if path.contains("/node_modules/") {
        return Method::Npm;
    }
    let named = exe.file_stem().is_some_and(|n| n == "skillcask");
    let dir = exe.parent();
    let is_dir = |d: PathBuf| std::fs::canonicalize(d).ok().is_some_and(|d| Some(d.as_path()) == dir);
    if let Some(home) = cargo_home
        && named
        && is_dir(home.join("bin"))
        && std::fs::read(home.join(".crates2.json")).is_ok_and(|b| lists_skillcask(&b))
    {
        return Method::Cargo;
    }
    if let Some(prefix) = receipt_dir.and_then(|d| receipt_prefix(&d.join("skillcask-receipt.json")))
        && named
        && is_dir(prefix.join("bin"))
    {
        return Method::Installer(prefix);
    }
    Method::Unknown
}

/// `{"installs": {"skillcask 0.10.1 (registry+…)": {…}}}`
fn lists_skillcask(crates2: &[u8]) -> bool {
    serde_json::from_slice::<serde_json::Value>(crates2)
        .ok()
        .and_then(|v| v.get("installs")?.as_object().map(|o| o.keys().any(|k| k.starts_with("skillcask "))))
        .unwrap_or(false)
}

/// The `install_prefix` of a `cargo-home` receipt; other layouts are not rerun.
fn receipt_prefix(path: &Path) -> Option<PathBuf> {
    let v: serde_json::Value = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
    if v.get("install_layout")?.as_str()? != "cargo-home" {
        return None;
    }
    Some(PathBuf::from(v.get("install_prefix")?.as_str().filter(|p| !p.is_empty())?))
}

#[cfg(unix)]
fn installer(verbose: bool, latest: &str, prefix: &Path, dry_run: bool) -> Result<()> {
    use std::io::{Seek, Write};
    use std::os::unix::process::CommandExt;

    use crate::error::{IO, NETWORK};
    use crate::self_check::https_url;

    const LIMIT: u64 = 256 * 1024;
    let base = https_url("SKILLCASK_SELF_UPDATE_URL", &format!("{RELEASES}/download"))?;
    let url = format!("{}/v{latest}/skillcask-installer.sh", base.trim_end_matches('/'));
    let shown = crate::http::shown_url(&url);
    if std::env::var_os("SKILLCASK_SELF_UPDATE_URL").is_some_and(|v| !v.is_empty()) {
        crate::ui::warn(format!("installer from {shown} (SKILLCASK_SELF_UPDATE_URL)"));
    }
    // The script skips its archive check without sha256sum (dist 0.32 has no shasum fallback).
    if !on_path("sha256sum") {
        let (_, command) = advice(&Method::Installer(prefix.into()), latest, false).expect("installer advice");
        return Err(Error::new(MANIFEST, "the installer needs sha256sum to check the archive, and it is not on PATH")
            .hint(format!("install it (coreutils), or check the archive yourself after: {command}")));
    }
    if dry_run {
        println!("would run {shown} with /bin/sh to update skillcask {RUNNING} -> {latest} in {}", prefix.display());
        return Ok(());
    }
    let hint = format!("check the connection; releases are listed at {RELEASES}");
    let body = crate::http::Http::anonymous(verbose)?
        .get(&url, LIMIT)
        .map_err(|e| Error { code: NETWORK, hint: Some(hint.clone()), ..e })?
        .ok_or_else(|| Error::new(NETWORK, format!("{shown}: not found")).hint(hint))?;
    // Unnamed: nothing is left in the temp dir once sh exits.
    let mut script = tempfile::tempfile()?;
    script.write_all(&body)?;
    script.rewind()?;
    crate::ui::note(format!("updating skillcask {RUNNING} -> {latest} with {shown}"));
    let mut cmd = std::process::Command::new("/bin/sh");
    // The script reads these to change where archives come from, which token goes with them, and
    // where or whether it installs; only what this update decides may reach it.
    for (k, _) in std::env::vars_os() {
        let k = k.to_string_lossy();
        if ["SKILLCASK_", "INSTALLER_", "CARGO_DIST_"].iter().any(|p| k.starts_with(p)) {
            cmd.env_remove(&*k);
        }
    }
    // exec, not spawn: no skillcask process runs while the installer replaces the binary
    // (Linux refuses to write a running executable, macOS may kill one whose pages change).
    let err = cmd.arg("-s").stdin(script).env("SKILLCASK_INSTALL_DIR", prefix).env("SKILLCASK_NO_MODIFY_PATH", "1").exec();
    Err(Error::new(IO, format!("cannot run /bin/sh: {err}")))
}

#[cfg(unix)]
fn on_path(name: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|p| std::env::split_paths(&p).any(|d| d.join(name).is_file()))
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixture {
        _dir: tempfile::TempDir,
        root: PathBuf,
        cargo: PathBuf,
        receipts: PathBuf,
        exe: PathBuf,
    }

    fn fixture() -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(dir.path()).unwrap();
        let (cargo, receipts) = (root.join(".cargo"), root.join(".config/skillcask"));
        std::fs::create_dir_all(cargo.join("bin")).unwrap();
        std::fs::create_dir_all(&receipts).unwrap();
        let exe = cargo.join("bin/skillcask");
        std::fs::write(&exe, "").unwrap();
        Fixture { _dir: dir, root, cargo, receipts, exe }
    }

    impl Fixture {
        fn receipt(&self, layout: &str, prefix: &Path) {
            let r = serde_json::json!({ "install_layout": layout, "install_prefix": prefix, "version": "0.10.1" });
            std::fs::write(self.receipts.join("skillcask-receipt.json"), r.to_string()).unwrap();
        }
        fn crates2(&self, home: &Path, key: &str) {
            let c = serde_json::json!({ "installs": { key: { "bins": ["skillcask"] } } });
            std::fs::write(home.join(".crates2.json"), c.to_string()).unwrap();
        }
        fn detect(&self) -> Method {
            detect(&self.exe, Some(&self.cargo), Some(&self.receipts))
        }
    }

    #[test]
    fn package_managers_by_path() {
        let none = |p: &str| detect(Path::new(p), None, None);
        assert_eq!(none("/opt/homebrew/Cellar/skillcask/0.10.1/bin/skillcask"), Method::Homebrew);
        assert_eq!(none("/home/linuxbrew/.linuxbrew/Cellar/skillcask/0.10.1/bin/skillcask"), Method::Homebrew);
        assert!(matches!(none("/Applications/Skillcask.app/Contents/Helpers/skillcask"), Method::App(_)));
        assert_eq!(none("/Users/a/.bun/install/global/node_modules/skillcask/skillcask"), Method::Bun);
        assert_eq!(none("/usr/lib/node_modules/skillcask/node_modules/.bin_skillcask/skillcask"), Method::Npm);
        assert_eq!(none(r"C:\Users\a\AppData\Roaming\npm\node_modules\skillcask\skillcask.exe"), Method::Npm);
        assert_eq!(none("/usr/local/bin/skillcask"), Method::Unknown);
    }

    #[test]
    fn the_installer_receipt() {
        let f = fixture();
        f.receipt("cargo-home", &f.cargo);
        assert_eq!(f.detect(), Method::Installer(f.cargo.clone()));
    }

    #[test]
    fn cargo_install_wins_over_a_stale_receipt() {
        let f = fixture();
        f.receipt("cargo-home", &f.cargo);
        f.crates2(&f.cargo, "skillcask 0.10.1 (registry+https://github.com/rust-lang/crates.io-index)");
        assert_eq!(f.detect(), Method::Cargo);
    }

    #[test]
    fn neither_matches() {
        let f = fixture();
        assert_eq!(f.detect(), Method::Unknown, "no receipt, no crates2");
        f.crates2(&f.cargo, "other 1.0.0 (registry+https://github.com/rust-lang/crates.io-index)");
        assert_eq!(f.detect(), Method::Unknown, "crates2 without skillcask");
        f.receipt("flat", &f.cargo.join("bin"));
        assert_eq!(f.detect(), Method::Unknown, "a flat layout is not rerun");
        f.receipt("cargo-home", &f.root.join("elsewhere"));
        assert_eq!(f.detect(), Method::Unknown, "the receipt names another prefix");
        std::fs::write(f.receipts.join("skillcask-receipt.json"), "{").unwrap();
        assert_eq!(f.detect(), Method::Unknown, "unreadable receipt");
        // `.crates2.json` of another CARGO_HOME says nothing about this binary.
        f.receipt("cargo-home", &f.cargo);
        let renamed = f.cargo.join("bin/skillcask-old");
        std::fs::write(&renamed, "").unwrap();
        assert_eq!(detect(&renamed, Some(&f.cargo), Some(&f.receipts)), Method::Unknown, "not the receipt's binary");
        std::fs::remove_file(f.receipts.join("skillcask-receipt.json")).unwrap();
        let other = f.root.join("other-cargo");
        std::fs::create_dir_all(other.join("bin")).unwrap();
        f.crates2(&other, "skillcask 0.10.1 (registry+https://github.com/rust-lang/crates.io-index)");
        assert_eq!(detect(&f.exe, Some(&other), Some(&f.receipts)), Method::Unknown);
    }

    #[test]
    fn one_pasteable_command_per_method() {
        let cmd = |m: Method, windows: bool| advice(&m, "1.2.3", windows).map(|(_, c)| c);
        let ps = cmd(Method::Installer(PathBuf::new()), true).unwrap();
        assert_eq!(
            ps,
            "powershell -ExecutionPolicy Bypass -c \"irm https://github.com/GetResponse/skillcask/releases/download/v1.2.3/skillcask-installer.ps1 | iex\""
        );
        let sh = cmd(Method::Installer(PathBuf::new()), false).unwrap();
        assert!(sh.contains("/download/v1.2.3/skillcask-installer.sh | sh"), "{sh}");
        assert_eq!(cmd(Method::App(true), false).unwrap(), "brew update && brew upgrade skillcask skillcask-app");
        let app = cmd(Method::App(false), false).unwrap();
        assert!(app.ends_with("/download/v1.2.3/skillcask-app-installer.sh | SKILLCASK_VERSION=1.2.3 sh"), "{app}");
        assert_eq!(cmd(Method::Unknown, false), None);
        for m in [Method::Homebrew, Method::Npm, Method::Bun, Method::Cargo, Method::App(true), Method::App(false)] {
            let c = cmd(m, false).unwrap();
            assert!(!c.contains(", or") && !c.contains('('), "{c}");
        }
    }
}
