//! `self-update` (D52): rerun the release's shell installer for an installer-script install on
//! Unix; for every other install, name the one command that updates it, or the package to deploy.

use std::path::{Path, PathBuf};

use crate::error::{Error, MANIFEST, Result};
use crate::self_check::{RELEASES, RUNNING, is_newer, latest_release};

#[derive(Debug, PartialEq)]
enum Method {
    /// The CLI inside `Skillcask.app`; `true` when a Caskroom folder of Homebrew's cask exists.
    App(bool),
    /// The CLI inside the `Skillcask.app` that the macOS installer package put there (D69).
    Pkg,
    Homebrew,
    Npm,
    Bun,
    Cargo,
    /// dist's shell or PowerShell installer, with the receipt's `install_prefix`.
    Installer(PathBuf),
    Unknown,
}

const CASKROOMS: [&str; 2] = ["/opt/homebrew/Caskroom/skillcask-app", "/usr/local/Caskroom/skillcask-app"];

/// Where Installer keeps the receipts of third-party packages.
const PKG_RECEIPTS_DIR: &str = "/var/db/receipts";
/// The receipt of the package's app component.
const PKG_RECEIPT: &str = "com.getresponse.skillcask.pkg.app.plist";
/// The user Installer writes the app as: root.
const PKG_OWNER: u32 = 0;

pub fn run(verbose: bool, dry_run: bool) -> Result<()> {
    let Some(latest) = latest_release(verbose)? else {
        return Err(Error::new(MANIFEST, "the latest skillcask version is unknown").hint(format!("see {RELEASES}")));
    };
    if !is_newer(&latest) {
        println!("skillcask {RUNNING} is the latest");
        return Ok(());
    }
    if let Some(managed) = crate::policy::updates_managed()? {
        return Err(
            Error::new(MANIFEST, format!("skillcask {RUNNING} -> {latest}: updates are managed by your organisation")).hint(managed)
        );
    }
    let exe = std::fs::canonicalize(std::env::current_exe()?)?;
    let pkg = cfg!(target_os = "macos").then_some((Path::new(PKG_RECEIPTS_DIR), PKG_OWNER));
    let method = detect(&exe, cargo_home().as_deref(), receipt_dir().as_deref(), pkg, &CASKROOMS);
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
    let then = then(&method);
    Err(Error::new(MANIFEST, format!("skillcask {RUNNING} -> {latest}: installed with {how}{why}; {then}")).hint(command))
}

/// What follows `installed with <method>`: the package has no command its user can run.
fn then(method: &Method) -> &'static str {
    if *method == Method::Pkg { "your administrator deploys updates" } else { "update with:" }
}

/// One pasteable command per method, for the package its file name and the release page (not the
/// asset's URL: the package is attached after the release and may not be there yet); `None` when
/// the method is unknown.
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
        Method::Pkg => {
            ("the macOS installer package", format!("the package Skillcask-{latest}-macos-universal.pkg is on {RELEASES}/tag/v{latest}"))
        }
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
/// The package comes before the cask: nothing removes its receipt or a Caskroom folder when the
/// app is installed another way later, so the helper's owner decides. `pkg` is the folder of
/// Installer's receipts and the uid Installer writes the helper as (root); the cask and the
/// installer script write it as the user.
fn detect(exe: &Path, cargo_home: Option<&Path>, receipt_dir: Option<&Path>, pkg: Option<(&Path, u32)>, caskrooms: &[&str]) -> Method {
    let path = exe.to_string_lossy().replace('\\', "/");
    if path.contains(".app/Contents/Helpers/") {
        if pkg.is_some_and(|(receipts, owner)| receipts.join(PKG_RECEIPT).is_file() && owned_by(exe, owner)) {
            return Method::Pkg;
        }
        return Method::App(caskrooms.iter().any(|c| Path::new(c).is_dir()));
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

#[cfg(unix)]
fn owned_by(path: &Path, uid: u32) -> bool {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(path).is_ok_and(|m| m.uid() == uid)
}

#[cfg(not(unix))]
fn owned_by(_: &Path, _: u32) -> bool {
    false
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
            detect(&self.exe, Some(&self.cargo), Some(&self.receipts), None, &[])
        }
    }

    #[test]
    fn package_managers_by_path() {
        let none = |p: &str| detect(Path::new(p), None, None, None, &[]);
        assert_eq!(none("/opt/homebrew/Cellar/skillcask/0.10.1/bin/skillcask"), Method::Homebrew);
        assert_eq!(none("/home/linuxbrew/.linuxbrew/Cellar/skillcask/0.10.1/bin/skillcask"), Method::Homebrew);
        assert_eq!(none("/Applications/Skillcask.app/Contents/Helpers/skillcask"), Method::App(false));
        assert_eq!(none("/Users/a/.bun/install/global/node_modules/skillcask/skillcask"), Method::Bun);
        assert_eq!(none("/usr/lib/node_modules/skillcask/node_modules/.bin_skillcask/skillcask"), Method::Npm);
        assert_eq!(none(r"C:\Users\a\AppData\Roaming\npm\node_modules\skillcask\skillcask.exe"), Method::Npm);
        assert_eq!(none("/usr/local/bin/skillcask"), Method::Unknown);
    }

    /// The helper of an app under the fixture, the package's receipts folder, a Caskroom folder
    /// and the uid the test's files have.
    #[cfg(unix)]
    fn app(f: &Fixture) -> (PathBuf, PathBuf, PathBuf, u32) {
        use std::os::unix::fs::MetadataExt;
        let helpers = f.root.join("Applications/Skillcask.app/Contents/Helpers");
        let (db, caskroom) = (f.root.join("db/receipts"), f.root.join("Caskroom/skillcask-app"));
        std::fs::create_dir_all(&helpers).unwrap();
        std::fs::create_dir_all(&db).unwrap();
        std::fs::write(helpers.join("skillcask"), "").unwrap();
        let me = std::fs::metadata(&f.root).unwrap().uid();
        (helpers.join("skillcask"), db, caskroom, me)
    }

    #[cfg(unix)]
    #[test]
    fn the_package_receipt_with_the_helper_its_installer_wrote() {
        let f = fixture();
        let (exe, db, caskroom, me) = app(&f);
        let cask = [caskroom.to_str().unwrap()];
        let pkg = |owner: u32, casks: &[&str]| detect(&exe, None, None, Some((&db, owner)), casks);
        // What `run` passes on macOS, literally: a typo in a constant must not pass.
        assert_eq!((PKG_RECEIPTS_DIR, PKG_RECEIPT, PKG_OWNER), ("/var/db/receipts", "com.getresponse.skillcask.pkg.app.plist", 0));
        assert_eq!(pkg(me, &[]), Method::App(false), "no receipt");
        std::fs::write(db.join("com.getresponse.skillcask.pkg.cli.plist"), "").unwrap();
        assert_eq!(pkg(me, &[]), Method::App(false), "only the CLI component's receipt");
        std::fs::write(db.join(PKG_RECEIPT), "").unwrap();
        assert_eq!(pkg(me, &[]), Method::Pkg);
        assert_eq!(detect(&exe, None, None, None, &[]), Method::App(false), "not macOS");
        // Reinstalled as the user since: the receipt is stale.
        assert_eq!(pkg(me + 1, &[]), Method::App(false));
        assert_eq!(pkg(me + 1, &cask), Method::App(false), "no Caskroom folder");
        std::fs::create_dir_all(&caskroom).unwrap();
        assert_eq!(pkg(me + 1, &cask), Method::App(true), "a stale receipt, the cask's app");
        assert_eq!(pkg(me, &cask), Method::Pkg, "a stale Caskroom folder, the package's app");
        assert_eq!(detect(&exe, None, None, None, &cask), Method::App(true));
        // The receipt says nothing about a skillcask outside the app.
        assert_eq!(detect(&f.exe, None, None, Some((&db, me)), &cask), Method::Unknown);
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
        assert_eq!(detect(&renamed, Some(&f.cargo), Some(&f.receipts), None, &[]), Method::Unknown, "not the receipt's binary");
        std::fs::remove_file(f.receipts.join("skillcask-receipt.json")).unwrap();
        let other = f.root.join("other-cargo");
        std::fs::create_dir_all(other.join("bin")).unwrap();
        f.crates2(&other, "skillcask 0.10.1 (registry+https://github.com/rust-lang/crates.io-index)");
        assert_eq!(detect(&f.exe, Some(&other), Some(&f.receipts), None, &[]), Method::Unknown);
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
        assert_eq!(
            advice(&Method::Pkg, "1.2.3", false).unwrap(),
            (
                "the macOS installer package",
                "the package Skillcask-1.2.3-macos-universal.pkg is on https://github.com/GetResponse/skillcask/releases/tag/v1.2.3".into()
            )
        );
        assert_eq!(then(&Method::Pkg), "your administrator deploys updates");
        assert_eq!(then(&Method::App(false)), "update with:");
        assert_eq!(cmd(Method::Unknown, false), None);
        for m in [Method::Homebrew, Method::Npm, Method::Bun, Method::Cargo, Method::App(true), Method::App(false)] {
            let c = cmd(m, false).unwrap();
            assert!(!c.contains(", or") && !c.contains('('), "{c}");
        }
    }
}
