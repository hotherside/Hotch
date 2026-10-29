mod sessions;
#[cfg(target_os = "linux")]
mod system;
#[cfg(target_os = "linux")]
mod tray;
mod usage;

use serde_json::{Value, json};

const HELP: &str = "\
hotch — AI plan usage, agent sessions and system load in the tray

usage: hotch [command] [--json]

  (none)     run the tray icon (Linux)
  usage      Claude and Codex plan usage
  sessions   live Claude Code and Codex sessions
  system     CPU, memory, battery (Linux)
  all        everything above
";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let json = args.iter().any(|a| a == "--json");
    let command = args.iter().find(|a| !a.starts_with("--")).map(String::as_str);

    match command {
        None if !args.iter().any(|a| a == "--help" || a == "-h") => tray(),
        Some("usage") => print(json, json!({"usage": usage_json()}), usage_text),
        Some("sessions") => print(json, json!({"sessions": sessions_json()}), sessions_text),
        Some("system") => print(json, json!({"system": system_json()}), system_text),
        Some("all") => print(
            json,
            json!({"usage": usage_json(), "sessions": sessions_json(), "system": system_json()}),
            |v| [usage_text(v), sessions_text(v), system_text(v)].join("\n"),
        ),
        Some("version") => println!("hotch {}", env!("CARGO_PKG_VERSION")),
        _ => print!("{HELP}"),
    }
}

#[cfg(target_os = "linux")]
fn tray() {
    tray::run()
}

#[cfg(not(target_os = "linux"))]
fn tray() {
    eprintln!("hotch: the tray is Linux only; on macOS use the Hotch app. Try `hotch usage`.");
    std::process::exit(1);
}

fn print(json: bool, value: Value, text: fn(&Value) -> String) {
    if json {
        println!("{value}");
    } else {
        print!("{}", text(&value));
    }
}

fn usage_json() -> Value {
    usage::fetch_all().iter().map(usage::Usage::to_json).collect()
}

fn sessions_json() -> Value {
    sessions::scan().iter().map(sessions::Session::to_json).collect()
}

#[cfg(target_os = "linux")]
fn system_json() -> Value {
    // Two readings a quarter second apart: a one-shot command has no previous tick.
    let (_, ticks) = system::sample(None);
    std::thread::sleep(std::time::Duration::from_millis(250));
    system::sample(Some(ticks)).0.to_json()
}

#[cfg(not(target_os = "linux"))]
fn system_json() -> Value {
    json!({"error": "unsupported on this OS"})
}

fn usage_text(v: &Value) -> String {
    let mut out = String::new();
    for u in v["usage"].as_array().into_iter().flatten() {
        out += &format!("{}\n", u["provider"].as_str().unwrap_or(""));
        if let Some(e) = u["error"].as_str() {
            out += &format!("  {e}\n");
        }
        for w in u["windows"].as_array().into_iter().flatten() {
            out += &format!(
                "  {:<14} {:>3.0}%\n",
                w["label"].as_str().unwrap_or(""),
                w["percent"].as_f64().unwrap_or(0.0)
            );
        }
        for x in u["extras"].as_array().into_iter().flatten() {
            out += &format!("  {}\n", x.as_str().unwrap_or(""));
        }
    }
    out
}

fn sessions_text(v: &Value) -> String {
    let rows = v["sessions"].as_array().cloned().unwrap_or_default();
    if rows.is_empty() {
        return "no active sessions\n".into();
    }
    rows.iter()
        .map(|s| {
            format!(
                "{:<7} {:<12} {:<20} {}\n",
                s["provider"].as_str().unwrap_or(""),
                s["activity"].as_str().unwrap_or(""),
                s["project"].as_str().unwrap_or(""),
                s["name"].as_str().unwrap_or("")
            )
        })
        .collect()
}

fn system_text(v: &Value) -> String {
    let s = &v["system"];
    if let Some(e) = s["error"].as_str() {
        return format!("system: {e}\n");
    }
    let mut out = format!(
        "CPU {:.0}% · RAM {:.1}/{:.0} GB",
        s["cpuPercent"].as_f64().unwrap_or(0.0),
        s["memUsedGB"].as_f64().unwrap_or(0.0),
        s["memTotalGB"].as_f64().unwrap_or(0.0)
    );
    if let Some(p) = s["battery"]["percent"].as_u64() {
        out += &format!(
            " · Bat {p}% {}",
            s["battery"]["status"].as_str().unwrap_or("").to_lowercase()
        );
    }
    out + "\n"
}
