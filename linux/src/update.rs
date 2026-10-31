//! A notify-only check for a newer Linux release. Hotch never downloads or
//! installs anything: the notice links to the GitHub release page.
//!
//! Versions move in lockstep with the macOS app, so a release can change
//! macOS alone. Such a release carries no `.deb` (see RELEASING.md), which is
//! why the newest release with a `.deb` for this architecture counts as the
//! latest Linux version.

use crate::settings::{self, Settings};
use crate::usage::{home, unix_now};
use serde_json::{Value, json};
use std::io::Read;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;
use std::{fs, thread};

const RELEASES: &str = "https://api.github.com/repos/hotherside/Hotch/releases?per_page=20";
const RELEASE_PAGE: &str = "https://github.com/hotherside/Hotch/releases/tag/";
const ACCEPT: &str = "Accept: application/vnd.github+json";
const DAY: i64 = 24 * 3600;
/// After a failed attempt (offline, rate-limited) the next waits an hour.
const RETRY: i64 = 3600;
const MAX_BYTES: u64 = 4 << 20;
const TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Check {
    /// The automatic check: only while enabled, once a day.
    IfDue,
    /// `hotch update-check` and Check now ask even with automatic checks off.
    Now,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Release {
    pub version: String,
    pub url: String,
}

#[derive(Debug, Clone, Default)]
pub struct Status {
    /// The newest Linux release at the last answered check.
    pub latest: Option<Release>,
    pub checked_at: Option<i64>,
    /// `latest` is newer than this build and not skipped.
    pub available: bool,
    /// Whether this call asked GitHub and got an answer; `None` if it did not ask.
    pub answered: Option<bool>,
}

impl Status {
    pub fn to_json(&self) -> Value {
        json!({
            "current": env!("CARGO_PKG_VERSION"),
            "latest": self.latest.as_ref().map(|r| &r.version),
            "url": self.latest.as_ref().map(|r| &r.url),
            "checkedAt": self.checked_at,
            "available": self.available,
        })
    }
}

/// Reads the cache, asks GitHub if `check` calls for it, and reports. Failures
/// are kept from the user: the last answer stands and the next try waits.
pub fn status(check: Check) -> Status {
    let settings = Settings::load();
    let mut cache = Cache::load();
    let enabled = settings.update_checks();
    let save = |cache: &Cache| settings::write_private(&cache_path(), cache.to_json().to_string().as_bytes()).is_ok();
    let answered = deb_arch().and_then(|arch| refresh(&mut cache, check, enabled, arch, unix_now(), save, fetch));
    summarise(cache, env!("CARGO_PKG_VERSION"), settings.skipped(), answered)
}

fn summarise(cache: Cache, current: &str, skipped: Option<&str>, answered: Option<bool>) -> Status {
    let available = cache
        .latest
        .as_ref()
        .is_some_and(|r| is_newer(&r.version, current) && skipped != Some(r.version.as_str()));
    Status {
        latest: cache.latest,
        checked_at: cache.checked_at,
        available,
        answered,
    }
}

// MARK: - Schedule

/// `update.json` in the cache directory: deleting it only means an early check.
#[derive(Debug, Clone, Default, PartialEq)]
struct Cache {
    /// Last answered check, Unix seconds.
    checked_at: Option<i64>,
    /// Last attempt, answered or not.
    attempted_at: Option<i64>,
    latest: Option<Release>,
}

fn cache_path() -> PathBuf {
    std::env::var_os("XDG_CACHE_HOME")
        .filter(|p| PathBuf::from(p).is_absolute())
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join(".cache"))
        .join("hotch/update.json")
}

impl Cache {
    fn load() -> Self {
        let v: Value = fs::read(cache_path())
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        Cache {
            checked_at: v["checkedAt"].as_i64(),
            attempted_at: v["attemptedAt"].as_i64(),
            latest: release(&v["latest"]),
        }
    }

    fn to_json(&self) -> Value {
        json!({
            "checkedAt": self.checked_at,
            "attemptedAt": self.attempted_at,
            "latest": self.latest.as_ref().map(|r| json!({"version": r.version, "url": r.url})),
        })
    }

    /// A day after the last answer and an hour after the last attempt. A clock
    /// that went backwards makes a check due rather than waiting it out.
    fn due(&self, now: i64) -> bool {
        let since = |at: Option<i64>, gap: i64| at.is_none_or(|t| now < t || now - t >= gap);
        since(self.checked_at, DAY) && since(self.attempted_at, RETRY)
    }
}

/// A cached release, trusted only if it still looks like one Hotch wrote: a
/// plain version and the release page of that very tag.
fn release(v: &Value) -> Option<Release> {
    let version = v["version"]
        .as_str()
        .filter(|s| !s.starts_with('v') && Version::parse(s).is_some())?;
    let tag = v["url"].as_str()?.strip_prefix(RELEASE_PAGE)?;
    (tag.strip_prefix('v').unwrap_or(tag) == version).then(|| Release {
        version: version.into(),
        url: format!("{RELEASE_PAGE}{tag}"),
    })
}

/// Asks once when `check` calls for it. A failure only moves `attempted_at`.
/// `save` writes the cache and says whether it could.
fn refresh(
    cache: &mut Cache,
    check: Check,
    enabled: bool,
    arch: &str,
    now: i64,
    save: impl Fn(&Cache) -> bool,
    fetch: impl FnOnce() -> Option<Value>,
) -> Option<bool> {
    if check == Check::IfDue && !(enabled && cache.due(now)) {
        return None;
    }
    // Recorded before asking, so GNOME, the tray and the CLI do not ask at
    // once. A cache that cannot be written (owned by root, read-only, full)
    // would otherwise make every poll a request, so the automatic check then
    // stays off.
    cache.attempted_at = Some(now);
    if !save(cache) && check == Check::IfDue {
        return None;
    }
    let Some(list) = fetch().filter(Value::is_array) else {
        return Some(false);
    };
    cache.checked_at = Some(now);
    cache.latest = latest_linux(&list, arch);
    save(cache);
    Some(true)
}

// MARK: - Releases

/// Debian's name for this machine, or `None` where Hotch ships no `.deb`.
pub fn deb_arch() -> Option<&'static str> {
    if !cfg!(target_os = "linux") {
        return None;
    }
    match std::env::consts::ARCH {
        "x86_64" => Some("amd64"),
        "aarch64" => Some("arm64"),
        _ => None,
    }
}

/// The newest published, non-prerelease release with a `.deb` for `arch`.
/// Versions decide, not list order.
fn latest_linux(releases: &Value, arch: &str) -> Option<Release> {
    let suffix = format!("_{arch}.deb");
    let has_deb = |r: &Value| {
        r["assets"].as_array().into_iter().flatten().any(|a| {
            a["name"]
                .as_str()
                .is_some_and(|n| n.starts_with("hotch_") && n.ends_with(&suffix))
                && a["state"].as_str().is_none_or(|s| s == "uploaded")
        })
    };
    let (_, tag) = releases
        .as_array()?
        .iter()
        .filter(|r| r["draft"] != true && r["prerelease"] != true && has_deb(r))
        .filter_map(|r| {
            let tag = r["tag_name"].as_str()?;
            Some((Version::parse(tag)?, tag))
        })
        .max_by(|a, b| a.0.cmp(&b.0))?;
    // The tag passed Version::parse, so it is safe in a URL.
    Some(Release {
        version: tag.strip_prefix('v').unwrap_or(tag).into(),
        url: format!("{RELEASE_PAGE}{tag}"),
    })
}

/// A release version: plain `MAJOR.MINOR.PATCH` after an optional `v`,
/// compared numerically. A suffixed tag (`v2.5.0-rc.1`) is never offered,
/// even when published without GitHub's prerelease flag.
#[derive(Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version([u64; 3]);

impl Version {
    pub fn parse(text: &str) -> Option<Self> {
        let text = text.strip_prefix('v').unwrap_or(text);
        let numbers: Vec<u64> = text.split('.').map(number).collect::<Option<_>>()?;
        Some(Version(numbers.try_into().ok()?))
    }
}

fn number(part: &str) -> Option<u64> {
    part.bytes().all(|b| b.is_ascii_digit()).then(|| part.parse().ok())?
}

/// Whether release `candidate` is newer than this build, which may be a
/// prerelease: 2.4.0 is newer than 2.4.0-beta.1.
pub fn is_newer(candidate: &str, current: &str) -> bool {
    let (core, pre) = current.split_once('-').unwrap_or((current, ""));
    match (Version::parse(candidate), Version::parse(core)) {
        (Some(candidate), Some(current)) => candidate > current || (candidate == current && !pre.is_empty()),
        _ => false,
    }
}

// MARK: - Request

/// GitHub's public release list through curl, or wget where curl is missing;
/// both honour the usual proxy variables. The request carries the Hotch
/// version and nothing about the user, their accounts or this machine.
fn fetch() -> Option<Value> {
    let agent = format!("Hotch/{} (Linux)", env!("CARGO_PKG_VERSION"));
    let curl = Command::new("curl")
        .args(["--silent", "--fail", "--location", "--max-time", "10"])
        .args(["--proto", "=https", "--proto-redir", "=https"])
        .args(["--user-agent", &agent, "--header", ACCEPT, RELEASES])
        .output_bounded();
    let body = match curl {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Command::new("wget")
            .args(["--quiet", "--output-document=-", "--timeout=10", "--tries=1"])
            .args([format!("--user-agent={agent}"), format!("--header={ACCEPT}")])
            .arg(RELEASES)
            .output_bounded(),
        other => other,
    };
    serde_json::from_slice(&body.ok()??).ok()
}

trait Bounded {
    /// Stdout of a successful run, at most `MAX_BYTES` within `TIMEOUT`.
    fn output_bounded(&mut self) -> std::io::Result<Option<Vec<u8>>>;
}

impl Bounded for Command {
    fn output_bounded(&mut self) -> std::io::Result<Option<Vec<u8>>> {
        let mut child = self
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let stdout = child.stdout.take().unwrap();
        let (tx, rx) = mpsc::channel();
        thread::spawn(move || {
            let mut body = Vec::new();
            let read = stdout.take(MAX_BYTES).read_to_end(&mut body);
            let _ = tx.send(read.ok().map(|_| body));
        });
        let body = rx.recv_timeout(TIMEOUT).ok().flatten();
        if body.is_none() {
            let _ = child.kill();
        }
        let ok = child.wait().is_ok_and(|s| s.success());
        Ok(body.filter(|_| ok))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn releases() -> Value {
        let deb = |v: &str, arch: &str| json!({"name": format!("hotch_{v}-1_{arch}.deb"), "state": "uploaded"});
        let dmg = |v: &str| json!({"name": format!("Hotch-{v}.dmg"), "state": "uploaded"});
        json!([
            {"tag_name": "v2.6.0", "assets": [dmg("2.6.0")]},
            {"tag_name": "v2.5.1", "prerelease": true, "assets": [deb("2.5.1", "amd64"), deb("2.5.1", "arm64")]},
            {"tag_name": "v2.5.0", "draft": true, "assets": [deb("2.5.0", "amd64"), deb("2.5.0", "arm64")]},
            {"tag_name": "v2.3.0", "assets": [dmg("2.3.0"), deb("2.3.0", "amd64"), deb("2.3.0", "arm64")]},
            {"tag_name": "v2.4.0", "assets": [dmg("2.4.0"), deb("2.4.0", "amd64")]},
            {"tag_name": "v2.5.0-rc.1", "assets": [deb("2.5.0-rc.1", "amd64"), deb("2.5.0-rc.1", "arm64")]},
            {"tag_name": "v2.10.0", "assets": [dmg("2.10.0"), {"name": "hotch_2.10.0-1_arm64.deb", "state": "open"}]}
        ])
    }

    fn kept(_: &Cache) -> bool {
        true
    }

    #[test]
    fn versions_compare_numerically() {
        assert!(is_newer("2.4.0", "2.3.0"));
        assert!(is_newer("v2.10.0", "2.9.9"));
        assert!(
            is_newer("2.4.0", "2.4.0-beta.1"),
            "a release is newer than its prerelease build"
        );
        assert!(!is_newer("2.4.0", "2.4.0"));
        assert!(!is_newer("2.2.9", "2.3.0"));
        assert!(!is_newer("2.5.0-rc.1", "2.4.0"), "suffixed tags are never offered");
        for bad in [
            "2.4",
            "2.4.0.1",
            "2.4.0-",
            "2.5.0-rc.1",
            "+2.4.0",
            "2.4.0+build",
            "latest",
            "",
        ] {
            assert!(Version::parse(bad).is_none(), "{bad}");
        }
    }

    #[test]
    fn only_releases_with_a_deb_for_this_architecture_count() {
        let amd64 = latest_linux(&releases(), "amd64").unwrap();
        assert_eq!(amd64.version, "2.4.0");
        assert_eq!(amd64.url, "https://github.com/hotherside/Hotch/releases/tag/v2.4.0");
        assert_eq!(latest_linux(&releases(), "arm64").unwrap().version, "2.3.0");
        assert_eq!(
            latest_linux(&json!([{"tag_name": "v2.6.0", "assets": []}]), "amd64"),
            None
        );
        assert_eq!(latest_linux(&json!({"message": "rate limited"}), "amd64"), None);
    }

    #[test]
    fn checks_daily_and_never_while_disabled() {
        let mut cache = Cache::default();
        let never = || -> Option<Value> { panic!("disabled checks must not reach the network") };
        assert_eq!(
            refresh(&mut cache, Check::IfDue, false, "amd64", 1000, kept, never),
            None
        );
        assert_eq!(cache, Cache::default());

        assert_eq!(
            refresh(&mut cache, Check::IfDue, true, "amd64", 1000, kept, || Some(releases())),
            Some(true)
        );
        assert_eq!(cache.latest.as_ref().unwrap().version, "2.4.0");
        assert_eq!(
            refresh(&mut cache, Check::IfDue, true, "amd64", 1000 + DAY - 1, kept, never),
            None
        );
        let checked = refresh(&mut cache, Check::IfDue, true, "amd64", 1000 + DAY, kept, || {
            Some(json!([]))
        });
        assert_eq!(checked, Some(true));
        assert_eq!(cache.latest, None);

        // On demand asks at once, even with automatic checks off.
        let now = refresh(&mut cache, Check::Now, false, "arm64", 1000 + DAY + 5, kept, || {
            Some(releases())
        });
        assert_eq!(now, Some(true));
        assert_eq!(cache.latest.unwrap().version, "2.3.0");
    }

    #[test]
    fn offline_failure_is_silent_keeps_the_last_answer_and_retries_hourly() {
        let mut cache = Cache::default();
        refresh(&mut cache, Check::IfDue, true, "amd64", 1000, kept, || Some(releases()));
        let later = 1000 + 2 * DAY;
        assert_eq!(
            refresh(&mut cache, Check::IfDue, true, "amd64", later, kept, || None),
            Some(false)
        );
        assert_eq!(cache.checked_at, Some(1000));
        assert_eq!(cache.attempted_at, Some(later));
        assert_eq!(cache.latest.as_ref().unwrap().version, "2.4.0");
        // A rate-limit body is not a release list.
        let limited = || Some(json!({"message": "API rate limit exceeded"}));
        assert_eq!(
            refresh(&mut cache, Check::Now, true, "amd64", later + 1, kept, limited),
            Some(false)
        );
        assert_eq!(cache.latest.as_ref().unwrap().version, "2.4.0");
        assert!(!cache.due(later + 1 + RETRY - 1));
        assert!(cache.due(later + 1 + RETRY));
        assert!(cache.due(0), "a clock moved backwards checks again");
    }

    #[test]
    fn attempts_are_saved_before_asking_and_an_unwritable_cache_stops_automatic_checks() {
        let saved = std::cell::RefCell::new(vec![]);
        let record = |cache: &Cache| {
            saved.borrow_mut().push(cache.clone());
            true
        };
        let fetch = || {
            let attempt = saved.borrow().last().cloned().unwrap();
            assert_eq!((attempt.attempted_at, attempt.checked_at), (Some(1000), None));
            Some(releases())
        };
        let mut cache = Cache::default();
        assert_eq!(
            refresh(&mut cache, Check::IfDue, true, "amd64", 1000, record, fetch),
            Some(true)
        );
        assert_eq!(saved.into_inner().last(), Some(&cache));

        let never = || -> Option<Value> { panic!("an unwritable cache must not make every poll a request") };
        let mut cache = Cache::default();
        assert_eq!(
            refresh(&mut cache, Check::IfDue, true, "amd64", 1000, |_| false, never),
            None
        );
        // Asked for explicitly, it still answers.
        let now = refresh(
            &mut cache,
            Check::Now,
            true,
            "amd64",
            1000,
            |_| false,
            || Some(releases()),
        );
        assert_eq!(now, Some(true));
    }

    #[test]
    fn skipped_or_older_releases_are_not_available() {
        let cache = Cache {
            checked_at: Some(1000),
            attempted_at: Some(1000),
            latest: latest_linux(&releases(), "amd64"),
        };
        assert!(summarise(cache.clone(), "2.3.0", None, None).available);
        assert!(summarise(cache.clone(), "2.3.0", Some("2.3.9"), None).available);
        assert!(!summarise(cache.clone(), "2.3.0", Some("2.4.0"), None).available);
        assert!(!summarise(cache.clone(), "2.4.0", None, None).available);
        let status = summarise(cache.clone(), "2.3.0", None, Some(true));
        assert_eq!(status.to_json()["latest"], "2.4.0");
        assert_eq!(status.to_json()["checkedAt"], 1000);
        assert_eq!(release(&cache.to_json()["latest"]), cache.latest);
        for url in [
            "https://example.com/",
            "https://github.com/hotherside/Hotch/releases/tag/v2.5.0",
            "https://github.com/hotherside/Hotch/releases/tag/../../../../x/y/releases",
        ] {
            assert_eq!(release(&json!({"version": "2.4.0", "url": url})), None, "{url}");
        }
        assert_eq!(
            release(&json!({"version": "2.5.0-rc.1", "url": format!("{RELEASE_PAGE}v2.5.0-rc.1")})),
            None
        );
    }
}
