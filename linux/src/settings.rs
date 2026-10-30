//! Shared preferences for the tray, CLI and GNOME extension. No credentials.
use crate::usage::home;
use serde_json::{Value, json};
use std::fs;
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

pub const HOMES: &[&str] = &["panel", "pill", "orb", "edge-left", "edge-right", "edge-bottom"];

pub fn path() -> PathBuf {
    std::env::var_os("XDG_CONFIG_HOME")
        .filter(|p| PathBuf::from(p).is_absolute())
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join(".config"))
        .join("hotch/gnome.json")
}

#[derive(Clone)]
pub struct Settings(pub Value);

impl Default for Settings {
    fn default() -> Self {
        Self(json!({"home":"panel", "theme":"system", "displayMode":"used",
            "refreshSeconds":60, "providers":["claude","codex"], "clipboardEnabled":false,
            "updateChecks":true, "updateSkipped":""}))
    }
}

impl Settings {
    pub fn load() -> Self {
        let raw = fs::read(path())
            .ok()
            .and_then(|b| serde_json::from_slice::<Value>(&b).ok());
        let mut settings = Self::default();
        if let Some(raw) = raw.and_then(|v| v.as_object().cloned()) {
            for (key, value) in raw {
                if valid(&key, &value) {
                    settings.0[&key] = value;
                }
            }
        }
        settings
    }

    pub fn providers(&self) -> Vec<String> {
        self.0["providers"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|v| v.as_str().map(String::from))
            .collect()
    }

    #[cfg(target_os = "linux")]
    pub fn refresh(&self) -> u64 {
        self.0["refreshSeconds"].as_u64().unwrap_or(60)
    }
    pub fn remaining(&self) -> bool {
        self.0["displayMode"] == "remaining"
    }

    /// The daily automatic check; `hotch update-check` asks regardless.
    pub fn update_checks(&self) -> bool {
        self.0["updateChecks"] != false
    }

    /// The release the user chose to skip in the update notice.
    pub fn skipped(&self) -> Option<&str> {
        self.0["updateSkipped"].as_str().filter(|v| !v.is_empty())
    }

    pub fn save(&self) -> std::io::Result<()> {
        write_private(&path(), self.0.to_string().as_bytes())
    }
}

/// Replaces `target` atomically with a file only this user can read, in a
/// directory only they can list.
pub fn write_private(target: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let dir = target.parent().unwrap();
    fs::create_dir_all(dir)?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    let name = target.file_name().unwrap_or_default().to_string_lossy();
    let temp = dir.join(format!(".{name}-{}.tmp", std::process::id()));
    let result = (|| {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&temp, target)
    })();
    let _ = fs::remove_file(temp);
    result
}

fn valid(key: &str, value: &Value) -> bool {
    match key {
        "home" => value.as_str().is_some_and(|v| HOMES.contains(&v)),
        "theme" => value.as_str().is_some_and(|v| ["system", "dark", "light"].contains(&v)),
        "displayMode" => value.as_str().is_some_and(|v| ["used", "remaining"].contains(&v)),
        "refreshSeconds" => value.as_u64().is_some_and(|v| [30, 60, 120, 300].contains(&v)),
        "providers" => value
            .as_array()
            .is_some_and(|a| a.iter().all(|v| matches!(v.as_str(), Some("claude" | "codex")))),
        "clipboardEnabled" | "updateChecks" => value.is_boolean(),
        "updateSkipped" => value
            .as_str()
            .is_some_and(|v| v.is_empty() || crate::update::Version::parse(v).is_some()),
        "pillX" | "pillY" => value.as_f64().is_some_and(|v| v.is_finite()),
        "focus" => value.is_object(),
        _ => false,
    }
}

pub fn command(args: &[String]) -> Result<(), String> {
    let mut settings = Settings::load();
    let args: Vec<_> = args.iter().filter(|s| *s != "--json").collect();
    if !args.is_empty() {
        if args.len() != 3 || args[0] != "set" {
            return Err("Use: hotch settings [set KEY VALUE] [--json]".into());
        }
        let key = args[1];
        let value = serde_json::from_str(args[2]).unwrap_or_else(|_| Value::String(args[2].clone()));
        if !valid(key, &value) {
            return Err(format!("Unsupported setting or value: {key}"));
        }
        settings.0[key] = value;
        settings.save().map_err(|e| e.to_string())?;
    }
    println!("{}", json!({"path":path(),"settings":settings.0}));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reject_invalid_preferences() {
        assert!(!valid("refreshSeconds", &json!(0)));
        assert!(!valid("providers", &json!(["unknown"])));
        assert!(!valid("clipboardEnabled", &json!("true")));
        assert!(valid("providers", &json!([])));
        assert!(valid("home", &json!("edge-left")));
        assert!(valid("updateChecks", &json!(false)));
        assert!(!valid("updateChecks", &json!("off")));
        assert!(valid("updateSkipped", &json!("2.4.0")));
        assert!(valid("updateSkipped", &json!("")));
        assert!(!valid("updateSkipped", &json!("latest")));
    }

    #[test]
    fn update_checks_default_on() {
        let settings = Settings::default();
        assert!(settings.update_checks());
        assert_eq!(settings.skipped(), None);
        let off = Settings(json!({"updateChecks": false, "updateSkipped": "2.4.0"}));
        assert!(!off.update_checks());
        assert_eq!(off.skipped(), Some("2.4.0"));
    }
}
