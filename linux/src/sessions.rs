//! Live Claude Code and Codex sessions, from the files the CLIs already keep.
//! Port of the parts of Sources/Hotch/Providers/SessionMonitor.swift a glance
//! needs. Only names and states are read; transcript text never leaves here.

use crate::usage::home;
use serde_json::{Value, json};
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// Sort order is the enum order: what needs a person first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Activity {
    NeedsInput,
    Working,
    Shell,
    Waiting,
    Ended,
}

impl Activity {
    pub fn as_str(self) -> &'static str {
        match self {
            Activity::NeedsInput => "needs input",
            Activity::Working => "working",
            Activity::Shell => "shell",
            Activity::Waiting => "waiting",
            Activity::Ended => "ended",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Session {
    pub provider: &'static str,
    pub name: String,
    pub project: String,
    pub activity: Activity,
    /// What a session that needs input is waiting on, in Claude Code's words.
    pub waiting_for: Option<String>,
    pub last_event: SystemTime,
}

impl Session {
    pub fn to_json(&self) -> Value {
        json!({
            "provider": self.provider, "name": self.name, "project": self.project,
            "activity": self.activity.as_str(),
            "waitingFor": self.waiting_for,
            "lastEventAt": self.last_event.duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0),
        })
    }
}

const ACTIVE_WINDOW: Duration = Duration::from_secs(90);
const PENDING_TOOL_GRACE: Duration = Duration::from_secs(60);
const MID_TURN_LIMIT: Duration = Duration::from_secs(600);
const RECENT_CUTOFF: Duration = Duration::from_secs(12 * 3600);
const MAX_SESSIONS: usize = 5;
const TAIL_BYTES: u64 = 256 * 1024;

pub fn scan() -> Vec<Session> {
    let now = SystemTime::now();
    let mut out = claude_sessions(now);
    out.extend(codex_sessions(now));
    out.sort_by(|a, b| a.activity.cmp(&b.activity).then(b.last_event.cmp(&a.last_event)));
    out.truncate(MAX_SESSIONS);
    out
}

// MARK: - Claude

fn claude_sessions(now: SystemTime) -> Vec<Session> {
    let root = home().join(".claude");
    let mut seen = Vec::new();
    let mut out = Vec::new();
    for entry in read_dir(&root.join("sessions")) {
        if entry.extension().is_none_or(|e| e != "json") {
            continue;
        }
        let Some(d) = fs::read(&entry)
            .ok()
            .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        else {
            continue;
        };
        let (Some(id), Some(pid)) = (d["sessionId"].as_str(), d["pid"].as_i64()) else {
            continue;
        };
        if d["kind"] == "daemon" || !process_alive(pid) || seen.iter().any(|s| s == id) {
            continue;
        }
        seen.push(id.to_string());
        let cwd = d["cwd"].as_str().unwrap_or("");
        // Hotch's own usage read runs in the temp dir and registers like a session.
        if Path::new(cwd) == std::env::temp_dir() {
            continue;
        }

        let transcript = transcript_path(&root, id, cwd);
        let tail = transcript.as_deref().map(tail_lines).unwrap_or_default();
        let mtime = transcript.as_deref().and_then(mtime);
        let age = mtime.and_then(|m| now.duration_since(m).ok()).unwrap_or_default();

        let activity = match d["status"].as_str() {
            Some("busy") => Activity::Working,
            Some("shell") => Activity::Shell,
            Some("waiting") => Activity::NeedsInput,
            Some("idle") => Activity::Waiting,
            _ => transcript_activity(&tail, age),
        };
        let registry_name = d["name"].as_str().filter(|n| !n.is_empty());
        let name = match registry_name {
            Some(n) if d["nameSource"] != "derived" => n.to_string(),
            _ => title(&tail)
                .or(registry_name.map(String::from))
                .unwrap_or_else(|| id.chars().take(8).collect()),
        };
        let status_at = d["statusUpdatedAt"].as_f64().map(epoch);
        out.push(Session {
            provider: "claude",
            name,
            project: project_name(cwd),
            activity,
            waiting_for: d["waitingFor"]
                .as_str()
                .filter(|w| !w.is_empty() && activity == Activity::NeedsInput)
                .map(String::from),
            last_event: [mtime, status_at].into_iter().flatten().max().unwrap_or(now),
        });
    }
    out
}

/// Claude Code flattens every non-alphanumeric character of the cwd to "-".
/// The scheme is undocumented, so a miss falls back to searching every project.
fn transcript_path(root: &Path, id: &str, cwd: &str) -> Option<PathBuf> {
    let projects = root.join("projects");
    let slug: String = cwd.chars().map(|c| if c.is_alphanumeric() { c } else { '-' }).collect();
    let file = format!("{id}.jsonl");
    let derived = projects.join(slug).join(&file);
    if derived.is_file() {
        return Some(derived);
    }
    read_dir(&projects)
        .into_iter()
        .map(|d| d.join(&file))
        .find(|p| p.is_file())
}

/// Only conversation turns count: Claude Code appends bookkeeping lines
/// (titles, modes) after a turn ends, which must not read as activity.
fn transcript_activity(lines: &[Value], age: Duration) -> Activity {
    let last = lines
        .iter()
        .rev()
        .find(|l| l["type"] == "assistant" || l["type"] == "user");
    match last {
        None if age < ACTIVE_WINDOW => Activity::Working,
        None => Activity::Waiting,
        Some(l) if l["type"] == "assistant" => match l["message"]["stop_reason"].as_str() {
            Some("end_turn") => Activity::Waiting,
            Some("tool_use") | None if age < PENDING_TOOL_GRACE => Activity::Working,
            Some("tool_use") | None => Activity::NeedsInput,
            _ => Activity::Waiting,
        },
        Some(_) if age < MID_TURN_LIMIT => Activity::Working,
        Some(_) => Activity::Waiting,
    }
}

/// A title the person set (`/rename`) beats the generated one; newest of each wins.
fn title(lines: &[Value]) -> Option<String> {
    let pick = |ty: &str, key: &str| {
        lines.iter().rev().filter(|l| l["type"] == ty).find_map(|l| {
            l[key]
                .as_str()
                .map(str::trim)
                .filter(|t| !t.is_empty())
                .map(String::from)
        })
    };
    pick("custom-title", "customTitle").or_else(|| pick("ai-title", "aiTitle"))
}

// MARK: - Codex

/// Codex has no live registry: rollout files under `sessions/YYYY/MM/DD/`
/// are named with the session UUID and grow while it runs, so their mtime is
/// the liveness signal. Today's and yesterday's folders only.
fn codex_sessions(now: SystemTime) -> Vec<Session> {
    let root = home().join(".codex");
    let names = codex_names(&root);
    let mut out = Vec::new();
    for days_back in 0..2 {
        let (y, m, d) = civil_from_days(unix(now) / 86400 - days_back);
        let dir = root.join(format!("sessions/{y:04}/{m:02}/{d:02}"));
        for file in read_dir(&dir) {
            let fname = file.file_name().and_then(|f| f.to_str()).unwrap_or("");
            let Some(base) = fname.strip_suffix(".jsonl.zst").or(fname.strip_suffix(".jsonl")) else {
                continue;
            };
            if base.len() <= 36 {
                continue;
            }
            let id = &base[base.len() - 36..];
            let Some(mtime) = mtime(&file) else { continue };
            let age = now.duration_since(mtime).unwrap_or_default();
            if age >= RECENT_CUTOFF {
                continue;
            }
            out.push(Session {
                provider: "codex",
                name: names
                    .iter()
                    .find(|(i, _)| i == id)
                    .map(|(_, n)| n.clone())
                    .unwrap_or("Codex session".into()),
                project: if fname.ends_with(".zst") {
                    String::new()
                } else {
                    codex_project(&file)
                },
                activity: if age < ACTIVE_WINDOW {
                    Activity::Working
                } else {
                    Activity::Ended
                },
                waiting_for: None,
                last_event: mtime,
            });
        }
    }
    out
}

fn codex_names(root: &Path) -> Vec<(String, String)> {
    tail_lines(&root.join("session_index.jsonl"))
        .into_iter()
        .filter_map(|l| {
            Some((
                l["id"].as_str()?.to_string(),
                l["thread_name"].as_str().filter(|n| !n.is_empty())?.to_string(),
            ))
        })
        .collect()
}

/// The rollout's first line is session metadata carrying the cwd somewhere.
fn codex_project(file: &Path) -> String {
    let mut head = vec![0; 64 * 1024];
    let n = fs::File::open(file).and_then(|mut f| f.read(&mut head)).unwrap_or(0);
    let first = head[..n].split(|b| *b == b'\n').next().unwrap_or(&[]);
    serde_json::from_slice::<Value>(first)
        .ok()
        .and_then(|v| find_key(&v, "cwd"))
        .map(|c| project_name(&c))
        .unwrap_or_default()
}

fn find_key(v: &Value, key: &str) -> Option<String> {
    match v {
        Value::Object(m) => m
            .get(key)
            .and_then(|c| c.as_str().map(String::from))
            .or_else(|| m.values().find_map(|c| find_key(c, key))),
        Value::Array(a) => a.iter().find_map(|c| find_key(c, key)),
        _ => None,
    }
}

// MARK: - Shared

/// Cowork runs sessions in generated worktrees under the project; the project
/// is the name a person recognises.
fn project_name(cwd: &str) -> String {
    let path = cwd.split("/.claude/worktrees/").next().unwrap_or(cwd);
    path.rsplit('/').find(|s| !s.is_empty()).unwrap_or("").to_string()
}

fn process_alive(pid: i64) -> bool {
    // ponytail: /proc only; pid reuse is not checked against procStart like the Mac build does.
    pid > 0 && (Path::new(&format!("/proc/{pid}")).exists() || !cfg!(target_os = "linux"))
}

fn read_dir(dir: &Path) -> Vec<PathBuf> {
    fs::read_dir(dir)
        .map(|r| r.flatten().map(|e| e.path()).collect())
        .unwrap_or_default()
}

fn mtime(p: &Path) -> Option<SystemTime> {
    fs::metadata(p).and_then(|m| m.modified()).ok()
}

/// Decoded JSON lines from the last 256 KB, oldest first. The first partial
/// line simply fails to decode.
fn tail_lines(p: &Path) -> Vec<Value> {
    let Ok(mut f) = fs::File::open(p) else { return vec![] };
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    let _ = f.seek(SeekFrom::Start(len.saturating_sub(TAIL_BYTES)));
    let mut buf = Vec::new();
    let _ = f.read_to_end(&mut buf);
    buf.split(|b| *b == b'\n')
        .filter_map(|l| serde_json::from_slice(l).ok())
        .collect()
}

fn epoch(n: f64) -> SystemTime {
    let secs = if n > 1e11 { n / 1000.0 } else { n };
    SystemTime::UNIX_EPOCH + Duration::from_secs_f64(secs.max(0.0))
}

fn unix(t: SystemTime) -> i64 {
    t.duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Howard Hinnant's civil-from-days (UTC).
pub fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn activity_from_transcript() {
        let end = json!({"type": "assistant", "message": {"stop_reason": "end_turn"}});
        let tool = json!({"type": "assistant", "message": {"stop_reason": "tool_use"}});
        let title = json!({"type": "ai-title", "aiTitle": "Port to Linux"});
        let s = Duration::from_secs;
        assert_eq!(
            transcript_activity(&[end.clone(), title.clone()], s(1)),
            Activity::Waiting
        );
        assert_eq!(
            transcript_activity(std::slice::from_ref(&tool), s(5)),
            Activity::Working
        );
        assert_eq!(transcript_activity(&[tool], s(120)), Activity::NeedsInput);
        assert_eq!(super::title(&[end, title]), Some("Port to Linux".into()));
    }

    #[test]
    fn names_and_dates() {
        assert_eq!(project_name("/home/a/Hotch/.claude/worktrees/upbeat-x"), "Hotch");
        assert_eq!(project_name("/home/a/Hotch/"), "Hotch");
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(20752), (2026, 10, 26));
    }
}
