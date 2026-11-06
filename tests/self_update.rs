//! `self-update` (D52): rerun the installer for an installer-script install, else name the command.
mod common;

use common::*;

const CASK: &str = "/Casks/skillcask-app.rb";
const BASE: &str = "/releases/download";
#[cfg(unix)]
const INSTALLER: &str = "/releases/download/v999.0.0/skillcask-installer.sh";
const RUNNING: &str = env!("CARGO_PKG_VERSION");

fn cask(version: &str) -> String {
    format!("cask \"skillcask-app\" do\n  version \"{version}\"\n  sha256 \"0000\"\nend\n")
}

fn project(s: &Server) -> Project {
    let mut p = Project::new(s);
    let cargo = p.home().join(".cargo");
    p.env.push(("SKILLCASK_SELF_CHECK_URL".into(), s.url(CASK)));
    p.env.push(("SKILLCASK_SELF_UPDATE_URL".into(), s.url(BASE)));
    p.env.push(("CARGO_HOME".into(), cargo.display().to_string()));
    p
}

#[test]
fn up_to_date_does_nothing() {
    let s = Server::start();
    s.put(CASK, cask(RUNNING));
    let p = project(&s);
    assert!(p.ok(&["self-update"]).contains(&format!("skillcask {RUNNING} is the latest")));
    assert!(s.requests().iter().all(|r| r.path == CASK));
}

#[test]
fn an_unknown_install_names_the_release() {
    let s = Server::start();
    s.put(CASK, cask("999.0.0"));
    let p = project(&s);
    for args in [&["self-update"][..], &["self-update", "--dry-run"]] {
        let out = p.expect(args, 1);
        assert!(out.contains(&format!("skillcask {RUNNING} -> 999.0.0: cannot tell how skillcask was installed")), "{out}");
        assert!(out.contains("hint:") && out.contains("releases/tag/v999.0.0"), "{out}");
    }
    assert!(s.requests().iter().all(|r| r.path == CASK));
}

#[test]
fn an_unreadable_latest_is_an_error() {
    let s = Server::start();
    s.put(CASK, "<html>oops</html>");
    let out = project(&s).expect(&["self-update"], 1);
    assert!(out.contains("the latest skillcask version is unknown"), "{out}");
}

/// The test binary copied to `~/.cargo/bin`, as dist's installer would put it, with a `PATH` that
/// holds only a stub `sha256sum`.
#[cfg(unix)]
fn installed(s: &Server) -> Project {
    use std::os::unix::fs::PermissionsExt;
    let mut p = project(s);
    let tools = p.home().join("tools");
    std::fs::create_dir_all(&tools).unwrap();
    std::fs::write(tools.join("sha256sum"), "#!/bin/sh\n").unwrap();
    std::fs::set_permissions(tools.join("sha256sum"), std::fs::Permissions::from_mode(0o755)).unwrap();
    p.env.push(("PATH".into(), tools.display().to_string()));
    let cargo = p.home().join(".cargo");
    std::fs::create_dir_all(cargo.join("bin")).unwrap();
    let bin = cargo.join("bin/skillcask");
    std::fs::copy(env!("CARGO_BIN_EXE_skillcask"), &bin).unwrap();
    p.bin = Some(bin);
    let receipts = p.home().join(".config/skillcask");
    std::fs::create_dir_all(&receipts).unwrap();
    let receipt = serde_json::json!({ "install_layout": "cargo-home", "install_prefix": cargo, "version": RUNNING });
    std::fs::write(receipts.join("skillcask-receipt.json"), receipt.to_string()).unwrap();
    p
}

#[cfg(unix)]
#[test]
fn reruns_the_installer() {
    let s = Server::start();
    s.put(CASK, cask("999.0.0"));
    s.put(
        INSTALLER,
        "printf '%s %s [%s%s%s%s]\\n' \"$SKILLCASK_INSTALL_DIR\" \"$SKILLCASK_NO_MODIFY_PATH\" \"$SKILLCASK_DOWNLOAD_URL\" \"$SKILLCASK_GITHUB_TOKEN\" \"$INSTALLER_BASE_URL\" \"$CARGO_DIST_FORCE_INSTALL_DIR\" > \"$HOME/ran\"\n",
    );
    let mut p = installed(&s);
    // What would redirect the script's downloads, send it a token or move the install.
    for k in ["SKILLCASK_DOWNLOAD_URL", "SKILLCASK_GITHUB_TOKEN", "INSTALLER_BASE_URL", "CARGO_DIST_FORCE_INSTALL_DIR"] {
        p.env.push((k.into(), "x".into()));
    }
    let ran = p.home().join("ran");

    let out = p.ok(&["self-update", "--dry-run"]);
    assert!(out.contains("warning: installer from") && out.contains("(SKILLCASK_SELF_UPDATE_URL)"), "{out}");
    assert!(out.contains("would run") && out.contains(INSTALLER) && out.contains(&format!("{RUNNING} -> 999.0.0")), "{out}");
    assert!(!ran.exists() && s.requests().iter().all(|r| r.path == CASK));

    let out = p.ok(&["self-update"]);
    assert!(out.contains(&format!("updating skillcask {RUNNING} -> 999.0.0")), "{out}");
    let cargo = p.home().join(".cargo");
    assert_eq!(std::fs::read_to_string(&ran).unwrap(), format!("{} 1 []\n", cargo.display()));

    // exec hands the installer's exit code straight back.
    s.put(INSTALLER, "exit 7\n");
    p.expect(&["self-update"], 7);
}

#[cfg(unix)]
#[test]
fn installer_download_errors_exit_3() {
    let s = Server::start();
    s.put(CASK, cask("999.0.0"));
    let mut p = installed(&s);
    let out = p.expect(&["self-update"], 3);
    assert!(out.contains("skillcask-installer.sh: not found"), "{out}");
    p.env.push(("SKILLCASK_SELF_UPDATE_URL".into(), s.url(BASE).replace("https:", "http:")));
    let out = p.expect(&["self-update"], 3);
    assert!(out.contains("refusing non-HTTPS URL") && out.contains("SKILLCASK_SELF_UPDATE_URL must be an https:// URL"), "{out}");
}

#[cfg(unix)]
#[test]
fn cargo_install_gets_the_cargo_command() {
    let s = Server::start();
    s.put(CASK, cask("999.0.0"));
    let p = installed(&s);
    let crates2 = r#"{"installs":{"skillcask 0.10.1 (registry+https://github.com/rust-lang/crates.io-index)":{"bins":["skillcask"]}}}"#;
    std::fs::write(p.home().join(".cargo/.crates2.json"), crates2).unwrap();
    let out = p.expect(&["self-update"], 1);
    assert!(out.contains("installed with cargo install") && out.contains("cargo install --locked skillcask"), "{out}");
}

#[cfg(unix)]
#[test]
fn opted_out_or_without_sha256sum_prints_the_installer_command() {
    let s = Server::start();
    s.put(CASK, cask("999.0.0"));
    s.put(INSTALLER, "touch \"$HOME/ran\"\n");
    let mut p = installed(&s);
    p.env.push(("SKILLCASK_SELF_UPDATE".into(), "0".into()));
    let out = p.expect(&["self-update"], 1);
    assert!(out.contains("installed with the shell installer (SKILLCASK_SELF_UPDATE=0); update with:"), "{out}");
    assert!(out.contains("releases/download/v999.0.0/skillcask-installer.sh | sh"), "{out}");

    let mut p = installed(&s);
    p.env.push(("PATH".into(), p.home().join("empty").display().to_string()));
    let out = p.expect(&["self-update"], 1);
    assert!(out.contains("needs sha256sum") && out.contains("skillcask-installer.sh | sh"), "{out}");
    assert!(!p.home().join("ran").exists() && s.requests().iter().all(|r| r.path == CASK));
}

#[cfg(unix)]
#[test]
fn managed_updates_run_no_installer_and_name_who_updates() {
    let s = Server::start();
    s.put(CASK, cask("999.0.0"));
    let p = installed(&s);
    p.config("[updates]\nmanaged = \"mine\"\n");
    p.system_config("[updates]\nmanaged = \"Jamf installs updates; ask #it-help\"\n");
    for args in [&["self-update"][..], &["self-update", "--dry-run"]] {
        let out = p.expect(args, 1);
        assert!(out.contains(&format!("skillcask {RUNNING} -> 999.0.0: updates are managed by your organisation")), "{out}");
        assert!(out.contains("hint: Jamf installs updates; ask #it-help") && !out.contains("mine"), "{out}");
    }
    assert!(s.requests().iter().all(|r| r.path == CASK), "no installer download");
    let check = p.ok(&["self-check", "--json"]);
    assert!(check.contains(r#""managed":"Jamf installs updates; ask #it-help""#), "{check}");
}
