//! StatusNotifierItem tray (Ubuntu's AppIndicator extension shows these).
//! A worker thread refreshes once a minute; nothing runs in between.

use crate::sessions::{self, Session};
use crate::system::{self, System};
use crate::usage::{self, Usage};
use ksni::blocking::TrayMethods;
use ksni::menu::StandardItem;
use ksni::{Icon, MenuItem, ToolTip};
use std::sync::mpsc;
use std::time::{Duration, SystemTime};

const REFRESH: Duration = Duration::from_secs(60);
const ACCENT: [u8; 3] = [0xE8, 0x83, 0x3A];
const ALERT: [u8; 3] = [0xE5, 0x48, 0x4D];

struct Hotch {
    usages: Vec<Usage>,
    sessions: Vec<Session>,
    system: System,
    refresh: mpsc::Sender<()>,
}

impl Hotch {
    /// The fullest session window across providers: what the icon draws.
    fn headline(&self) -> Option<f64> {
        self.usages
            .iter()
            .filter_map(|u| u.windows.first())
            .map(|w| w.percent)
            .reduce(f64::max)
    }

    fn summary(&self) -> String {
        let parts: Vec<String> = self
            .usages
            .iter()
            .filter_map(|u| Some(format!("{} {:.0}%", title(u.provider), u.windows.first()?.percent)))
            .collect();
        if parts.is_empty() {
            "Hotch".into()
        } else {
            parts.join(" · ")
        }
    }
}

impl ksni::Tray for Hotch {
    const MENU_ON_ACTIVATE: bool = true;

    fn id(&self) -> String {
        "hotch".into()
    }

    fn title(&self) -> String {
        self.summary()
    }

    /// Panel text beside the ring: each connected provider's session percent,
    /// in a fixed order. The tooltip and menu name them.
    fn label(&self) -> String {
        let parts: Vec<String> = self
            .usages
            .iter()
            .filter_map(|u| Some(format!("{:.0}%", u.windows.first()?.percent)))
            .collect();
        parts.join(" · ")
    }

    fn label_guide(&self) -> String {
        vec!["100%"; self.usages.iter().filter(|u| !u.windows.is_empty()).count()].join(" · ")
    }

    fn icon_pixmap(&self) -> Vec<Icon> {
        vec![ring(32, self.headline())]
    }

    fn tool_tip(&self) -> ToolTip {
        ToolTip {
            title: self.summary(),
            description: self.system.line(),
            ..Default::default()
        }
    }

    fn menu(&self) -> Vec<MenuItem<Self>> {
        let info = |label: String| {
            StandardItem {
                label,
                enabled: false,
                ..Default::default()
            }
            .into()
        };
        let mut items: Vec<MenuItem<Self>> = Vec::new();
        let now = unix_now();

        for u in &self.usages {
            items.push(info(title(u.provider).into()));
            if let Some(e) = &u.error {
                items.push(info(format!("    {e}")));
            }
            for w in &u.windows {
                let reset = w
                    .resets_at
                    .map(|r| format!(" · resets in {}", relative(r - now)))
                    .unwrap_or_default();
                items.push(info(format!("    {}  {:.0}%{reset}", w.label, w.percent)));
            }
            for x in &u.extras {
                items.push(info(format!("    {x}")));
            }
        }

        items.push(MenuItem::Separator);
        if self.sessions.is_empty() {
            items.push(info("No active sessions".into()));
        }
        for s in &self.sessions {
            let project = if s.project.is_empty() {
                String::new()
            } else {
                format!("{} — ", s.project)
            };
            items.push(info(format!(
                "{} {project}{} · {}",
                dot(s),
                s.name,
                s.activity.as_str()
            )));
        }

        items.push(MenuItem::Separator);
        items.push(info(self.system.line()));
        items.push(MenuItem::Separator);
        items.push(
            StandardItem {
                label: "Refresh".into(),
                activate: Box::new(|t: &mut Self| {
                    let _ = t.refresh.send(());
                }),
                ..Default::default()
            }
            .into(),
        );
        items.push(
            StandardItem {
                label: "Quit".into(),
                activate: Box::new(|_| std::process::exit(0)),
                ..Default::default()
            }
            .into(),
        );
        items
    }
}

pub fn run() {
    let (tx, rx) = mpsc::channel();
    let tray = Hotch {
        usages: vec![],
        sessions: vec![],
        system: System::default(),
        refresh: tx,
    };
    let handle = match tray.spawn() {
        Ok(h) => h,
        Err(e) => {
            eprintln!("hotch: no system tray available ({e}). On GNOME, enable the AppIndicator extension.");
            std::process::exit(1);
        }
    };

    let mut ticks = None;
    loop {
        // Sessions and system are cheap and local: show them before the
        // providers' CLIs answer.
        let (sys, t) = system::sample(ticks);
        ticks = Some(t);
        let found = sessions::scan();
        handle.update(|h| {
            h.system = sys;
            h.sessions = found;
        });
        let fresh = usage::fetch_all();
        let updated = handle.update(|h| {
            // A failed read (rate limited, offline) keeps the last good one,
            // as the Mac app does, rather than blanking the panel.
            // ponytail: no max age; the Mac app drops readings older than 2 h.
            let merged = fresh
                .into_iter()
                .map(|new| match h.usages.iter().find(|old| old.provider == new.provider) {
                    Some(old) if new.windows.is_empty() && !old.windows.is_empty() => old.clone(),
                    _ => new,
                })
                .collect();
            h.usages = merged;
        });
        if updated.is_none() {
            return;
        }
        // A Refresh click wakes early; a disconnected channel cannot happen
        // while the tray holds the sender.
        let _ = rx.recv_timeout(REFRESH);
        while rx.try_recv().is_ok() {}
    }
}

fn title(provider: &str) -> &str {
    match provider {
        "claude" => "Claude",
        "codex" => "Codex",
        other => other,
    }
}

fn dot(s: &Session) -> &'static str {
    match s.activity {
        sessions::Activity::NeedsInput => "◆",
        sessions::Activity::Working | sessions::Activity::Shell => "●",
        _ => "○",
    }
}

fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// "2h 14m", "3d 4h". Relative, so no time-zone database is needed.
fn relative(secs: i64) -> String {
    let m = secs.max(0) / 60;
    match (m / 1440, m / 60 % 24, m % 60) {
        (0, 0, m) => format!("{m}m"),
        (0, h, m) => format!("{h}h {m}m"),
        (d, h, _) => format!("{d}d {h}h"),
    }
}

/// A ring gauge: faint track, arc clockwise from 12 o'clock by `percent`.
/// Red from 90%. No percent yet (first launch) draws the track only.
fn ring(size: i32, percent: Option<f64>) -> Icon {
    let c = size as f64 / 2.0;
    let (outer, inner) = (c - 1.0, c * 0.58);
    let fill = percent.unwrap_or(0.0) / 100.0;
    let color = if percent.unwrap_or(0.0) >= 90.0 { ALERT } else { ACCENT };
    let mut data = Vec::with_capacity((size * size * 4) as usize);
    for y in 0..size {
        for x in 0..size {
            let (dx, dy) = (x as f64 + 0.5 - c, y as f64 + 0.5 - c);
            let r = dx.hypot(dy);
            // Soft edges: one pixel of coverage either side.
            let cover = (outer - r + 0.5).clamp(0.0, 1.0) * (r - inner + 0.5).clamp(0.0, 1.0);
            let angle = (dx.atan2(-dy) / std::f64::consts::TAU).rem_euclid(1.0);
            let (rgb, alpha) = if angle < fill {
                (color, 255.0)
            } else {
                ([0xFF; 3], 90.0)
            };
            data.extend([(alpha * cover) as u8, rgb[0], rgb[1], rgb[2]]);
        }
    }
    Icon {
        width: size,
        height: size,
        data,
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn relative_times() {
        assert_eq!(super::relative(59), "0m");
        assert_eq!(super::relative(2 * 3600 + 14 * 60), "2h 14m");
        assert_eq!(super::relative(3 * 86400 + 4 * 3600 + 5), "3d 4h");
    }
}
