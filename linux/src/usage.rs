//! Provider usage, read through the vendor CLIs the same way the macOS app does
//! (see Sources/Hotch/Providers/ClaudeCodeBridge.swift and CodexAppServer.swift).

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

const TIMEOUT: Duration = Duration::from_secs(12);

#[derive(Debug, Clone, PartialEq)]
pub struct Window {
    pub label: String,
    pub percent: f64,
    /// Unix seconds.
    pub resets_at: Option<i64>,
}

#[derive(Debug, Clone, Default)]
pub struct Usage {
    pub provider: &'static str,
    pub windows: Vec<Window>,
    pub extras: Vec<String>,
    /// "Team", "Pro lite": the subscription, as the vendor names it.
    pub plan: Option<String>,
    /// Set when the provider could not be read; `windows` is then empty.
    pub error: Option<String>,
    /// Time of the last successful reading, never the last failed attempt.
    pub fetched_at: Option<i64>,
    pub stale: bool,
}

impl Usage {
    fn failed(provider: &'static str, error: impl Into<String>) -> Self {
        Usage {
            provider,
            error: Some(error.into()),
            ..Default::default()
        }
    }

    pub fn to_json(&self) -> Value {
        json!({
            "provider": self.provider,
            "windows": self.windows.iter().map(|w| json!({
                "label": w.label, "percent": w.percent, "resetsAt": w.resets_at,
            })).collect::<Vec<_>>(),
            "extras": self.extras,
            "plan": self.plan,
            "error": self.error,
            "fetchedAt": self.fetched_at,
            "stale": self.stale,
        })
    }
}

pub fn fetch_all() -> Vec<Usage> {
    let claude = thread::spawn(claude);
    let codex = codex();
    let now = unix_now();
    vec![
        claude.join().unwrap_or_else(|_| Usage::failed("claude", "crashed")),
        codex,
    ]
    .into_iter()
    .map(|mut u| {
        if u.error.is_none() && !u.windows.is_empty() {
            u.fetched_at = Some(now);
        }
        u
    })
    .collect()
}

pub fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Preserve a bounded last good reading while keeping the new failure visible.
#[cfg(any(target_os = "linux", test))]
pub fn retain_last_good(new: Usage, old: Option<&Usage>, now: i64) -> Usage {
    if new.error.is_none() || !new.windows.is_empty() {
        return new;
    }
    match old.filter(|u| !u.windows.is_empty() && u.fetched_at.is_some_and(|t| now - t < 2 * 3600)) {
        Some(old) => Usage {
            error: new.error,
            stale: true,
            ..old.clone()
        },
        None => new,
    }
}

// MARK: - Binary lookup

pub fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default()
}

/// `$PATH` first, then where installers put the CLI when it is not on the
/// PATH a desktop session inherits.
fn locate(name: &str, extra: &[&str]) -> Option<PathBuf> {
    let home = home();
    std::env::var_os("PATH")
        .into_iter()
        .flat_map(|p| std::env::split_paths(&p).collect::<Vec<_>>())
        .map(|dir| dir.join(name))
        .chain(extra.iter().map(|rel| home.join(rel)))
        .chain(
            ["/usr/local/bin", "/usr/bin", "/opt/homebrew/bin"]
                .iter()
                .map(|d| PathBuf::from(d).join(name)),
        )
        .find(|p| p.is_file())
}

// MARK: - Child process plumbing

/// Kills the child after `TIMEOUT`, which also unblocks a pending read.
struct Session {
    child: Child,
    stdin: std::process::ChildStdin,
    lines: mpsc::Receiver<Value>,
}

impl Session {
    fn start(cmd: &mut Command) -> std::io::Result<Self> {
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        let stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, lines) = mpsc::channel();
        thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if let Ok(v) = serde_json::from_str(&line)
                    && tx.send(v).is_err()
                {
                    break;
                }
            }
        });
        Ok(Session { child, stdin, lines })
    }

    fn send(&mut self, v: Value) {
        let _ = writeln!(self.stdin, "{v}");
        let _ = self.stdin.flush();
    }

    /// Next decoded line, or `None` once the deadline passes or stdout closes.
    fn next(&self, deadline: std::time::Instant) -> Option<Value> {
        self.lines
            .recv_timeout(deadline.saturating_duration_since(std::time::Instant::now()))
            .ok()
    }

    fn stderr(&mut self) -> String {
        let _ = self.child.kill();
        let mut s = String::new();
        if let Some(mut e) = self.child.stderr.take() {
            let _ = e.read_to_string(&mut s);
        }
        s
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn deadline() -> std::time::Instant {
    std::time::Instant::now() + TIMEOUT
}

// MARK: - Claude

pub fn claude() -> Usage {
    let Some(bin) = locate(
        "claude",
        &[".local/bin/claude", ".claude/local/claude", ".npm-global/bin/claude"],
    ) else {
        return Usage::failed("claude", "Claude Code not installed");
    };
    match claude_exchange(&bin, true) {
        Err(Retry) => {
            claude_exchange(&bin, false).unwrap_or_else(|_| Usage::failed("claude", "Claude Code did not answer"))
        }
        Ok(u) => u,
    }
}

struct Retry;

fn claude_exchange(bin: &PathBuf, quiet: bool) -> Result<Usage, Retry> {
    let mut args = vec!["-p"];
    if quiet {
        args.extend(["--safe-mode", "--no-session-persistence"]);
    }
    args.extend([
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--verbose",
    ]);
    // Run outside any project so the read never picks up a project's settings.
    let dir = std::env::temp_dir();
    let mut s = match Session::start(
        Command::new(bin)
            .args(&args)
            .current_dir(dir)
            .env("DISABLE_AUTOUPDATER", "1"),
    ) {
        Ok(s) => s,
        Err(e) => return Ok(Usage::failed("claude", format!("could not start Claude Code: {e}"))),
    };
    s.send(json!({"type": "control_request", "request_id": "r1", "request": {"subtype": "initialize"}}));
    s.send(json!({"type": "control_request", "request_id": "r2",
                  "request": {"subtype": "get_usage", "skip_behaviors": true}}));

    let end = deadline();
    let mut saw_anything = false;
    while let Some(obj) = s.next(end) {
        saw_anything = true;
        if obj["type"] != "control_response" {
            continue;
        }
        let resp = &obj["response"];
        if resp["request_id"] != "r2" {
            continue;
        }
        if resp["subtype"] == "error" {
            let msg = resp["error"].as_str().unwrap_or("error");
            return Ok(Usage::failed("claude", format!("get_usage refused: {msg}")));
        }
        let body = &resp["response"];
        let (windows, extras) = body.get("rate_limits").map(parse_claude).unwrap_or_default();
        let error = windows.is_empty().then(|| "no usage windows reported".to_string());
        let plan = plan_name(body["subscription_type"].as_str());
        return Ok(Usage {
            provider: "claude",
            windows,
            extras,
            plan,
            error,
            ..Default::default()
        });
    }
    let tail = s.stderr();
    if !saw_anything && quiet && tail.to_lowercase().contains("unknown option") {
        return Err(Retry);
    }
    let detail = tail.lines().last().unwrap_or("").chars().take(160).collect::<String>();
    Ok(Usage::failed(
        "claude",
        format!("Claude Code did not answer get_usage {detail}")
            .trim()
            .to_string(),
    ))
}

/// Port of `ClaudeCodeBridge.parse(rateLimits:)`: server `limits[]` rows win,
/// the plain buckets are the fallback for older CLIs.
pub fn parse_claude(rl: &Value) -> (Vec<Window>, Vec<String>) {
    let mut windows: Vec<Window> = Vec::new();
    fn add(windows: &mut Vec<Window>, label: String, percent: f64, resets: Option<i64>) {
        if !windows.iter().any(|w| w.label == label) {
            windows.push(Window {
                label,
                percent: percent.clamp(0.0, 100.0),
                resets_at: resets,
            });
        }
    }

    for row in rl["limits"].as_array().into_iter().flatten() {
        let Some(percent) = num(&row["percent"]) else { continue };
        let kind = row["kind"].as_str().unwrap_or("").to_lowercase();
        let group = row["group"].as_str().unwrap_or("").to_lowercase();
        let scope = row["scope"]["model"]["display_name"]
            .as_str()
            .or(row["scope"]["surface"]["display_name"].as_str());
        let scoped = || format!("{} week", scope.unwrap_or("Scoped"));
        let label = match (kind.as_str(), group.as_str()) {
            ("session", _) => "Session".into(),
            ("weekly_all", _) => "Week".into(),
            ("weekly_scoped", _) => scoped(),
            // A meter this build has never seen: its group still says what family it is.
            (_, "session") => "Session".into(),
            (_, "weekly") if scope.is_none() => "Week".into(),
            (_, "weekly") => scoped(),
            _ => continue,
        };
        add(&mut windows, label, percent, date(&row["resets_at"]));
    }

    if windows.is_empty() {
        let bucket = |k: &str| num(&rl[k]["utilization"]).map(|p| (p, date(&rl[k]["resets_at"])));
        if let Some((p, r)) = bucket("five_hour") {
            add(&mut windows, "Session".into(), p, r);
        }
        if let Some((p, r)) = bucket("seven_day") {
            add(&mut windows, "Week".into(), p, r);
        }
        match rl["model_scoped"].as_array() {
            Some(rows) => {
                for row in rows {
                    if let (Some(name), Some(p)) = (row["display_name"].as_str(), num(&row["utilization"])) {
                        add(&mut windows, format!("{name} week"), p, date(&row["resets_at"]));
                    }
                }
            }
            None => {
                for (k, name) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
                    if let Some((p, r)) = bucket(k) {
                        add(&mut windows, format!("{name} week"), p, r);
                    }
                }
            }
        }
    }

    let mut extras = Vec::new();
    let extra = &rl["extra_usage"];
    let enabled = extra["is_enabled"].as_bool().unwrap_or(false);
    let used = num(&extra["used_credits"]).unwrap_or(0.0) / 100.0;
    if enabled || used > 0.0 {
        let cur = extra["currency"].as_str().unwrap_or("USD").to_uppercase();
        let mut line = format!("Extra usage {used:.2} {cur}");
        if let Some(limit) = num(&extra["monthly_limit"]).map(|l| l / 100.0).filter(|l| *l > 0.0) {
            line += &format!(" of {limit:.2}");
        }
        if !enabled {
            line += " (off)";
        }
        extras.push(line);
    }
    (windows, extras)
}

// MARK: - Codex

pub fn codex() -> Usage {
    let mut s = match codex_session() {
        Ok(s) => s,
        Err(e) => return Usage::failed("codex", e),
    };
    let end = deadline();
    s.send(json!({"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": null}));
    match codex_response(&s, 2, end) {
        Some(v) if v.get("result").is_some() => parse_codex(&v["result"]),
        Some(v) => Usage::failed("codex", v["error"]["message"].as_str().unwrap_or("error").to_string()),
        None => Usage::failed("codex", "codex app-server timed out"),
    }
}

/// Read the vendor's thread states instead of guessing approval from file age.
pub fn codex_threads() -> Option<Vec<Value>> {
    let mut s = codex_session().ok()?;
    s.send(json!({"jsonrpc": "2.0", "id": 2, "method": "thread/list",
        "params": {"limit": 100, "sortKey": "updated_at"}}));
    codex_response(&s, 2, deadline())?["result"]["data"].as_array().cloned()
}

fn codex_response(s: &Session, id: i64, end: std::time::Instant) -> Option<Value> {
    loop {
        let v = s.next(end)?;
        if v["id"] == id {
            return Some(v);
        }
    }
}

fn codex_session() -> Result<Session, String> {
    let Some(bin) = locate("codex", &[".local/bin/codex", ".npm-global/bin/codex"]) else {
        return Err("Codex CLI not installed".into());
    };
    let mut s = match Session::start(Command::new(&bin).arg("app-server")) {
        Ok(s) => s,
        Err(e) => return Err(format!("could not start codex: {e}")),
    };
    let end = deadline();
    s.send(json!({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                  "params": {"clientInfo": {"name": "hotch", "title": "Hotch", "version": env!("CARGO_PKG_VERSION")}}}));
    if codex_response(&s, 1, end).is_none_or(|v| v.get("error").is_some()) {
        return Err("codex app-server did not answer".into());
    }
    s.send(json!({"jsonrpc": "2.0", "method": "initialized"}));
    Ok(s)
}

/// Port of `CodexAppServer.parse(result:)`. The window length, not the bucket
/// name, decides what a bucket is.
pub fn parse_codex(result: &Value) -> Usage {
    let snap = &result["rateLimits"];
    if !snap.is_object() {
        return Usage::failed("codex", "unexpected rate limit shape");
    }
    let mut windows = Vec::new();
    for key in ["primary", "secondary"] {
        let b = &snap[key];
        let Some(p) = num(&b["usedPercent"]) else { continue };
        let label = match b["windowDurationMins"].as_i64().filter(|m| *m > 0) {
            Some(m) if m <= 12 * 60 => "Session".to_string(),
            Some(m) if m <= 36 * 60 => "Day".to_string(),
            Some(m) if (6 * 1440..=8 * 1440).contains(&m) => "Week".to_string(),
            Some(m) => format!("{}h", m / 60),
            None if key == "primary" => "Session".to_string(),
            None => "Week".to_string(),
        };
        windows.push(Window {
            label,
            percent: p.clamp(0.0, 100.0),
            resets_at: date(&b["resetsAt"]),
        });
    }
    let mut extras = Vec::new();
    if let Some(n) = result["rateLimitResetCredits"]["availableCount"]
        .as_i64()
        .filter(|n| *n > 0)
    {
        extras.push(if n == 1 {
            "1 reset credit".into()
        } else {
            format!("{n} reset credits")
        });
    }
    if windows.is_empty() {
        extras.push("No Codex limits on this plan".into());
    }
    let plan = plan_name(snap["planType"].as_str().or(result["planType"].as_str()));
    Usage {
        provider: "codex",
        windows,
        extras,
        plan,
        error: None,
        ..Default::default()
    }
}

// MARK: - JSON helpers

/// Port of `PlanName.display`.
fn plan_name(raw: Option<&str>) -> Option<String> {
    let raw = raw?.trim();
    if raw.is_empty() || raw.eq_ignore_ascii_case("unknown") {
        return None;
    }
    let known = match raw.to_lowercase().as_str() {
        "pro" => "Pro",
        "max" => "Max",
        "team" => "Team",
        "enterprise" => "Enterprise",
        "free" => "Free",
        "plus" => "Plus",
        "prolite" => "Pro lite",
        "promax" => "Pro max",
        "go" => "Go",
        "business" | "self_serve_business_usage_based" => "Business",
        "edu" => "Edu",
        "edu_plus" => "Edu Plus",
        "edu_pro" => "Edu Pro",
        "self_serve_business_prolite" => "Business Pro lite",
        "enterprise_cbp_automation" | "enterprise_cbp_usage_based" | "ent26" => "Enterprise",
        _ => "",
    };
    if !known.is_empty() {
        return Some(known.into());
    }
    let mut words = raw.split(['_', '-', ' ']).filter(|w| !w.is_empty());
    let first = words.next()?;
    let head = first[..1].to_uppercase() + &first[1..];
    Some(
        std::iter::once(head)
            .chain(words.map(String::from))
            .collect::<Vec<_>>()
            .join(" "),
    )
}

fn num(v: &Value) -> Option<f64> {
    v.as_f64().or_else(|| v.as_str()?.parse().ok())
}

/// Accepts Unix seconds, milliseconds, or an RFC 3339 string.
pub fn date(v: &Value) -> Option<i64> {
    if let Some(n) = v.as_f64() {
        return Some(if n > 1e11 { (n / 1000.0) as i64 } else { n as i64 });
    }
    parse_rfc3339(v.as_str()?)
}

/// "2026-10-26T14:00:00Z", "...+02:00", optional fraction. Std has no date
/// parser and this is the only format vendors send.
pub fn parse_rfc3339(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() < 19 {
        return None;
    }
    let n = |r: std::ops::Range<usize>| s.get(r)?.parse::<i64>().ok();
    let (y, mo, d, h, mi, se) = (n(0..4)?, n(5..7)?, n(8..10)?, n(11..13)?, n(14..16)?, n(17..19)?);
    let mut rest = &s[19..];
    if rest.starts_with('.') {
        rest = rest.trim_start_matches(|c: char| c == '.' || c.is_ascii_digit());
    }
    let offset = match rest {
        "" | "Z" | "z" => 0,
        tz if tz.len() == 6 => {
            let sign = if tz.starts_with('-') { -1 } else { 1 };
            sign * (tz[1..3].parse::<i64>().ok()? * 3600 + tz[4..6].parse::<i64>().ok()? * 60)
        }
        _ => return None,
    };
    Some(days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + se - offset)
}

/// Howard Hinnant's days-from-civil.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failed_refresh_keeps_age_and_error_then_expires() {
        let good = Usage {
            provider: "claude",
            fetched_at: Some(100),
            windows: vec![Window {
                label: "Session".into(),
                percent: 42.0,
                resets_at: None,
            }],
            ..Default::default()
        };
        let stale = retain_last_good(Usage::failed("claude", "Signed out"), Some(&good), 160);
        assert_eq!(stale.fetched_at, Some(100));
        assert_eq!(stale.error.as_deref(), Some("Signed out"));
        assert!(stale.stale);
        let expired = retain_last_good(Usage::failed("claude", "Offline"), Some(&stale), 7300);
        assert!(expired.windows.is_empty());
        let no_limits = parse_codex(&json!({"rateLimits": {}}));
        assert!(retain_last_good(no_limits, Some(&good), 160).windows.is_empty());
    }

    #[test]
    fn claude_limits_rows_win() {
        let rl = json!({
            "limits": [
                {"kind": "session", "percent": 42, "resets_at": "2026-10-26T14:00:00Z"},
                {"kind": "weekly_all", "percent": 63.5},
                {"kind": "weekly_scoped", "percent": 10, "scope": {"model": {"display_name": "Opus"}}},
                {"kind": "mystery", "group": "", "percent": 5}
            ],
            "five_hour": {"utilization": 99},
            "extra_usage": {"is_enabled": true, "used_credits": 1240, "monthly_limit": 5000}
        });
        let (w, e) = parse_claude(&rl);
        let labels: Vec<_> = w.iter().map(|w| w.label.as_str()).collect();
        assert_eq!(labels, ["Session", "Week", "Opus week"]);
        assert_eq!(w[0].percent, 42.0);
        assert_eq!(w[0].resets_at, Some(1793023200));
        assert_eq!(e, ["Extra usage 12.40 USD of 50.00"]);
    }

    #[test]
    fn claude_legacy_buckets() {
        let rl = json!({"five_hour": {"utilization": 12}, "seven_day": {"utilization": 140},
                        "seven_day_opus": {"utilization": 3}});
        let (w, e) = parse_claude(&rl);
        assert_eq!(
            w.iter().map(|w| w.label.as_str()).collect::<Vec<_>>(),
            ["Session", "Week", "Opus week"]
        );
        assert_eq!(w[1].percent, 100.0);
        assert!(e.is_empty());
    }

    #[test]
    fn codex_window_length_decides_label() {
        let r = json!({"rateLimits": {"primary": {"usedPercent": 30, "windowDurationMins": 10080, "resetsAt": 1793023200}},
                       "rateLimitResetCredits": {"availableCount": 2}});
        let u = parse_codex(&r);
        assert_eq!(
            u.windows,
            [Window {
                label: "Week".into(),
                percent: 30.0,
                resets_at: Some(1793023200)
            }]
        );
        assert_eq!(u.extras, ["2 reset credits"]);
        assert_eq!(plan_name(Some("prolite")).as_deref(), Some("Pro lite"));
        assert_eq!(plan_name(Some("new_tier")).as_deref(), Some("New tier"));
        assert!(parse_codex(&json!({})).error.is_some());
    }

    #[test]
    fn rfc3339() {
        assert_eq!(parse_rfc3339("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_rfc3339("2026-10-26T16:00:00.123+02:00"), Some(1793023200));
        assert_eq!(date(&json!(1793023200123u64)), Some(1793023200));
    }
}
