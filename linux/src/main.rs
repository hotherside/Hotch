mod sessions;
mod settings;
#[cfg(target_os = "linux")]
mod system;
#[cfg(target_os = "linux")]
mod tray;
mod update;
mod usage;

use serde_json::{Value, json};

const HELP: &str = "\
hotch — AI plan usage, agent sessions and system load in the tray

usage: hotch [command] [--json]

  (none)        run the tray icon (Linux)
  usage         Claude and Codex plan usage
  sessions      live Claude Code and Codex sessions
  system        CPU, memory, battery (Linux)
  all           everything above, plus a daily check for a newer Linux release
  settings      show preferences; settings set KEY VALUE changes one
  update-check  ask GitHub for a newer Linux release now; never installs it
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
        Some("all") => {
            // The daily update check runs beside the provider reads, not after them.
            let update = std::thread::spawn(|| update::status(update::Check::IfDue).to_json());
            let usage = usage_json();
            let value = json!({"usage": usage, "sessions": sessions_json(), "system": system_json(),
                "update": update.join().unwrap_or(Value::Null)});
            print(json, value, |v| {
                [usage_text(v), sessions_text(v), system_text(v)].join("\n") + &update_text(v)
            })
        }
        Some("update-check") => {
            let status = update::status(update::Check::Now);
            let answered = status.answered == Some(true);
            print(
                json,
                json!({"update": status.to_json(), "answered": answered}),
                update_check_text,
            );
            if !answered {
                std::process::exit(1);
            }
        }
        Some("version") => println!("hotch {}", env!("CARGO_PKG_VERSION")),
        Some("settings") => {
            if let Err(e) = settings::command(&args[1..]) {
                eprintln!("hotch: {e}");
                std::process::exit(2);
            }
        }
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
    let remaining = settings::Settings::load().remaining();
    let mut out = String::new();
    for u in v["usage"].as_array().into_iter().flatten() {
        out += &format!("{}\n", u["provider"].as_str().unwrap_or(""));
        if let Some(e) = u["error"].as_str() {
            out += &format!("  {e}\n");
        }
        for w in u["windows"].as_array().into_iter().flatten() {
            out += &format!(
                "  {:<14} {:>3.0}% {}\n",
                w["label"].as_str().unwrap_or(""),
                if remaining {
                    100.0 - w["percent"].as_f64().unwrap_or(0.0)
                } else {
                    w["percent"].as_f64().unwrap_or(0.0)
                },
                if remaining { "remaining" } else { "used" }
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

/// The notice line `hotch all` adds while automatic checks are on.
fn update_text(v: &Value) -> String {
    let u = &v["update"];
    if u["available"] != true || !settings::Settings::load().update_checks() {
        return String::new();
    }
    format!(
        "\nHotch {} is available: {}\n",
        u["latest"].as_str().unwrap_or(""),
        u["url"].as_str().unwrap_or("")
    )
}

fn update_check_text(v: &Value) -> String {
    let u = &v["update"];
    let current = u["current"].as_str().unwrap_or("");
    let latest = u["latest"].as_str().unwrap_or("");
    let url = u["url"].as_str().unwrap_or("");
    if update::deb_arch().is_none() {
        "Update checks cover the amd64 and arm64 Linux packages only.\n".into()
    } else if v["answered"] != true {
        "Could not check for updates right now; try again later.\n".into()
    } else if u["available"] == true {
        format!(
            "Hotch {latest} is available: {url}\nDownload the .deb for this machine there; Hotch never installs it.\n"
        )
    } else if update::is_newer(latest, current) {
        format!("Hotch {latest} is available but skipped: {url}\nhotch settings set updateSkipped '' shows it again.\n")
    } else {
        format!("Hotch {current} is up to date.\n")
    }
}
