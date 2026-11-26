//! Where Superwarm keeps its own files. Each location can be overridden with
//! an environment variable, which tests and unusual setups rely on.

use std::path::PathBuf;

fn app_dir_name() -> &'static str {
    // Matches the macOS app's Application Support folder; lowercase elsewhere.
    if cfg!(target_os = "macos") {
        "Superwarm"
    } else {
        "superwarm"
    }
}

fn from_env(key: &str) -> Option<PathBuf> {
    std::env::var_os(key).filter(|v| !v.is_empty()).map(PathBuf::from)
}

/// Settings: `models.json`, `remotes.json`. `$SUPERWARM_CONFIG_DIR` overrides.
pub fn config_dir() -> Option<PathBuf> {
    from_env("SUPERWARM_CONFIG_DIR").or_else(|| dirs::config_dir().map(|d| d.join(app_dir_name())))
}

/// Durable data: usage synced from remote machines. `$SUPERWARM_DATA_DIR` overrides.
pub fn data_dir() -> Option<PathBuf> {
    from_env("SUPERWARM_DATA_DIR").or_else(|| dirs::data_dir().map(|d| d.join(app_dir_name())))
}

/// Rebuildable data: the log parse cache. `$SUPERWARM_CACHE_DIR` overrides.
pub fn cache_dir() -> Option<PathBuf> {
    from_env("SUPERWARM_CACHE_DIR").or_else(|| dirs::cache_dir().map(|d| d.join("superwarm")))
}

/// This machine's short host name, used to label local usage next to remotes.
pub fn hostname() -> String {
    #[cfg(unix)]
    {
        let mut buf = [0u8; 256];
        // SAFETY: gethostname writes at most buf.len() bytes into buf.
        if unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) } == 0 {
            let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
            let name = String::from_utf8_lossy(&buf[..end]).into_owned();
            let short = name.split('.').next().unwrap_or(&name).to_string();
            if !short.is_empty() {
                return short;
            }
        }
    }
    "this machine".to_string()
}
