//! `superwarm settings` saves defaults that every later command uses.

use std::process::Command;

fn superwarm(config: &std::path::Path, home: &std::path::Path, args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_superwarm"))
        .args(args)
        .env("HOME", home)
        .env("CLAUDE_CONFIG_DIR", home.join(".claude"))
        .env("CODEX_HOME", home.join(".codex"))
        .env("SUPERWARM_CONFIG_DIR", config)
        .env("SUPERWARM_DATA_DIR", home.join("data"))
        .env("SUPERWARM_CACHE_DIR", home.join("cache"))
        .env("NO_COLOR", "1")
        .output()
        .unwrap()
}

fn json(out: std::process::Output) -> serde_json::Value {
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    serde_json::from_slice(&out.stdout).unwrap()
}

#[test]
fn saved_settings_are_used_until_reset() {
    let dir = tempfile::tempdir().unwrap();
    let (config, home) = (dir.path().join("config"), dir.path().join("home"));

    let defaults = json(superwarm(&config, &home, &["settings", "--json"]));
    assert_eq!(defaults["commuteMilesOneWay"], 11.7);
    assert!(!config.join("settings.json").exists(), "showing settings doesn't create the file");

    let saved = json(superwarm(&config, &home, &["settings", "--commute", "16.4", "--pue", "1.1", "--json"]));
    assert_eq!((saved["commuteMilesOneWay"].as_f64(), saved["pue"].as_f64()), (Some(16.4), Some(1.1)));
    assert_eq!(saved["gridGramsPerKwh"], 373.0);

    // Reports run with the saved values (an empty log folder still reports).
    assert!(superwarm(&config, &home, &["report", "today"]).status.success());

    let bad = superwarm(&config, &home, &["settings", "--pue", "0.5"]);
    assert!(!bad.status.success() && String::from_utf8_lossy(&bad.stderr).contains("PUE must be"));

    let reset = json(superwarm(&config, &home, &["settings", "--reset", "--json"]));
    assert_eq!(reset["pue"], 1.15);
}

#[test]
fn a_broken_settings_file_is_reported_and_can_be_reset() {
    let dir = tempfile::tempdir().unwrap();
    let (config, home) = (dir.path().join("config"), dir.path().join("home"));
    std::fs::create_dir_all(&config).unwrap();
    std::fs::write(config.join("settings.json"), "{ nope").unwrap();

    let out = superwarm(&config, &home, &["report", "today"]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("superwarm settings --reset"));
    // Demo data never reads saved settings.
    assert!(superwarm(&config, &home, &["--demo", "report", "today"]).status.success());

    assert_eq!(json(superwarm(&config, &home, &["settings", "--reset", "--json"]))["pue"], 1.15);
    assert!(superwarm(&config, &home, &["report", "today"]).status.success());
}
