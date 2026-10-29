//! CPU, memory and battery from /proc and /sys. Linux only; the Mac build has
//! its own IOKit readers.

use serde_json::{Value, json};
use std::fs;

#[derive(Debug, Default, Clone, Copy)]
pub struct CpuTicks {
    busy: u64,
    total: u64,
}

#[derive(Debug, Default, Clone)]
pub struct System {
    pub cpu_percent: Option<f64>,
    pub mem_used_gb: f64,
    pub mem_total_gb: f64,
    pub battery: Option<(u32, String)>,
}

impl System {
    pub fn to_json(&self) -> Value {
        json!({
            "cpuPercent": self.cpu_percent,
            "memUsedGB": self.mem_used_gb, "memTotalGB": self.mem_total_gb,
            "battery": self.battery.as_ref().map(|(p, s)| json!({"percent": p, "status": s})),
        })
    }

    pub fn line(&self) -> String {
        let mut parts = Vec::new();
        if let Some(c) = self.cpu_percent {
            parts.push(format!("CPU {c:.0}%"));
        }
        parts.push(format!("RAM {:.1}/{:.0} GB", self.mem_used_gb, self.mem_total_gb));
        if let Some((p, s)) = &self.battery {
            parts.push(format!("Bat {p}% {}", s.to_lowercase()));
        }
        parts.join(" · ")
    }
}

/// CPU is a delta between two readings: the caller keeps the previous ticks,
/// so the tray never sleeps to measure.
pub fn sample(prev: Option<CpuTicks>) -> (System, CpuTicks) {
    let ticks = cpu_ticks().unwrap_or_default();
    let cpu_percent = prev
        .filter(|p| ticks.total > p.total)
        .map(|p| 100.0 * (ticks.busy - p.busy.min(ticks.busy)) as f64 / (ticks.total - p.total) as f64);
    let (total, avail) = meminfo();
    let gb = |kb: u64| kb as f64 / 1024.0 / 1024.0;
    (
        System {
            cpu_percent,
            mem_used_gb: gb(total - avail.min(total)),
            mem_total_gb: gb(total),
            battery: battery(),
        },
        ticks,
    )
}

fn cpu_ticks() -> Option<CpuTicks> {
    let stat = fs::read_to_string("/proc/stat").ok()?;
    parse_cpu(stat.lines().next()?)
}

fn parse_cpu(line: &str) -> Option<CpuTicks> {
    let v: Vec<u64> = line
        .strip_prefix("cpu ")?
        .split_whitespace()
        .filter_map(|n| n.parse().ok())
        .collect();
    // user nice system idle iowait irq softirq steal
    let total: u64 = v.iter().take(8).sum();
    let idle = v.get(3)? + v.get(4).unwrap_or(&0);
    Some(CpuTicks {
        busy: total - idle,
        total,
    })
}

fn meminfo() -> (u64, u64) {
    let text = fs::read_to_string("/proc/meminfo").unwrap_or_default();
    let get = |key: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(key)?.trim().trim_end_matches("kB").trim().parse().ok())
            .unwrap_or(0)
    };
    (get("MemTotal:"), get("MemAvailable:"))
}

fn battery() -> Option<(u32, String)> {
    let dir = fs::read_dir("/sys/class/power_supply")
        .ok()?
        .flatten()
        .map(|e| e.path())
        .find(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with("BAT"))
        })?;
    let read = |f: &str| fs::read_to_string(dir.join(f)).ok().map(|s| s.trim().to_string());
    Some((read("capacity")?.parse().ok()?, read("status").unwrap_or_default()))
}

#[cfg(test)]
mod tests {
    #[test]
    fn cpu_line() {
        let t = super::parse_cpu("cpu  100 0 50 800 50 0 0 0 0 0").unwrap();
        assert_eq!((t.busy, t.total), (150, 1000));
    }
}
