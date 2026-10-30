// Hotch for GNOME Shell: the panel the macOS app draws, rebuilt from St
// widgets. Data comes from the `hotch` binary (`hotch all --json`); this file
// only draws. Colours, ring geometry and copy follow
// Sources/Hotch/Views/PanelModel.swift and HotchStyle.swift.

import GObject from 'gi://GObject';
import St from 'gi://St';
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Cairo from 'cairo';
import Shell from 'gi://Shell';
import Meta from 'gi://Meta';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {mergeUsage, readingStatus, updateNotice} from './data.js';
import {HOMES, normalizeSettings, displayedPercent, focusReading, focusAction,
    clockText, privateClipboard, rememberClipboard, companionPosition} from './model.js';

const STALE_SECONDS = 30;
const CRITICAL_PERCENT = 90;

const rgb = (r, g, b) => [r / 255, g / 255, b / 255];
const lift = c => c.map(v => Math.min(1, v + 0.2));

const BRANDS = {
    claude: {name: 'Claude', accent: rgb(0xF0, 0x86, 0x5F)},
    codex: {name: 'Codex', accent: rgb(0x96, 0x9A, 0xFF), highlight: rgb(0xBF, 0xC1, 0xFF)},
};
const WARNING = [1.0, 0.27, 0.23];
const CPU = [0.39, 0.82, 1.0];
const MEMORY = [1.0, 0.84, 0.04];
const POWER = [0.20, 0.84, 0.29];

const TABS = [
    {id: 'now', label: 'Now', icons: ['speedometer-symbolic', 'view-grid-symbolic']},
    {id: 'ai', label: 'AI', icons: ['starred-symbolic']},
    {id: 'sessions', label: 'Sessions', icons: ['utilities-terminal-symbolic']},
    {id: 'system', label: 'System', icons: ['computer-symbolic']},
    {id: 'focus', label: 'Focus', icons: ['alarm-symbolic']},
    {id: 'clipboard', label: 'Clipboard', icons: ['edit-paste-symbolic']},
];

// MARK: - Ring

/// Port of RingGauge: faint track, arc anchored at twelve o'clock growing
/// anti-clockwise, brand gradient from bottom-left to top-right, red from 90%.
const Ring = GObject.registerClass(
class HotchRing extends St.DrawingArea {
    _init(styleClass, lineWidth) {
        super._init({style_class: styleClass, y_align: Clutter.ActorAlign.CENTER});
        this._lineWidth = lineWidth;
        this._share = null;
        this._accent = BRANDS.claude.accent;
        this._highlight = lift(this._accent);
    }

    /// `warn` turns the ring red near the limit; off for readings where
    /// high is good, like a full battery.
    setValue(percent, accent, highlight, warn = true, remaining = false) {
        this._share = percent === null || percent === undefined ? null : displayedPercent(percent, remaining ? 'remaining' : 'used') / 100;
        const critical = warn && percent >= CRITICAL_PERCENT;
        this._accent = critical ? WARNING : accent;
        this._highlight = critical ? WARNING : highlight ?? lift(accent);
        this.queue_repaint();
    }

    vfunc_repaint() {
        const cr = this.get_context();
        const [w, h] = this.get_surface_size();
        const scale = St.ThemeContext.get_for_stage(global.stage).scale_factor;
        const lw = this._lineWidth * scale;
        const cx = w / 2, cy = h / 2, r = Math.min(w, h) / 2 - lw / 2;

        cr.setLineWidth(lw);
        const foreground = this.get_theme_node().get_foreground_color();
        cr.setSourceRGBA(foreground.red / 255, foreground.green / 255, foreground.blue / 255,
            this._share === null ? 0.11 : 0.16);
        cr.arc(cx, cy, r, 0, 2 * Math.PI);
        cr.stroke();

        if (this._share > 0) {
            const gradient = new Cairo.LinearGradient(0, h, w, 0);
            gradient.addColorStopRGBA(0, ...this._accent, 1);
            gradient.addColorStopRGBA(1, ...this._highlight, 1);
            cr.setSource(gradient);
            cr.setLineCap(Cairo.LineCap.ROUND);
            const top = -Math.PI / 2;
            cr.arcNegative(cx, cy, r, top, top - this._share * 2 * Math.PI);
            cr.stroke();
        }
        cr.$dispose();
    }
});

// MARK: - Small builders

const label = (text, styleClass, props = {}) =>
    new St.Label({text, style_class: styleClass, y_align: Clutter.ActorAlign.CENTER, ...props});

const vbox = (styleClass, props = {}) => new St.BoxLayout({orientation: Clutter.Orientation.VERTICAL, style_class: styleClass, ...props});
const hbox = (styleClass, props = {}) => new St.BoxLayout({style_class: styleClass, ...props});
const spacer = () => new St.Widget({x_expand: true});

function themedIcon(names, styleClass) {
    return new St.Icon({gicon: Gio.ThemedIcon.new_from_names(names), style_class: styleClass});
}

function relative(seconds) {
    const m = Math.max(0, Math.floor(seconds / 60));
    const d = Math.floor(m / 1440), h = Math.floor(m / 60) % 24;
    if (d > 0)
        return h > 0 ? `${d}d ${h}h` : `${d}d`;
    if (h > 0)
        return `${h}h ${m % 60}m`;
    return `${m}m`;
}

function ago(seconds) {
    if (seconds < 60)
        return `${Math.max(0, Math.round(seconds))}s ago`;
    return `${relative(seconds)} ago`;
}

const now = () => Date.now() / 1000;

/// The provider's brand mark, or null for a provider without one.
function markIcon(dir, provider, styleClass) {
    if (!BRANDS[provider])
        return null;
    return new St.Icon({
        gicon: Gio.FileIcon.new(dir.get_child('icons').get_child(`${provider}.svg`)),
        style_class: styleClass,
        y_align: Clutter.ActorAlign.CENTER,
    });
}

/// Port of AgentStatus.word, with Claude Code's own reason when it gave one.
function statusWord(s) {
    if (s.activity === 'needs input')
        return s.waitingFor || (s.provider === 'codex' ? 'needs approval' : 'needs you');
    return {working: 'working', waiting: 'idle', ended: 'ended'}[s.activity] ?? 'shell running';
}

// Where Hotch lives, in a small JSON file rather than GSettings so the
// extension installs by copying a folder.
const SETTINGS = GLib.build_filenamev([GLib.get_user_config_dir(), 'hotch', 'gnome.json']);

function loadSettings() {
    try {
        const [, bytes] = GLib.file_get_contents(SETTINGS);
        return normalizeSettings(JSON.parse(new TextDecoder().decode(bytes)));
    } catch {
        return normalizeSettings();
    }
}

function saveSettings(settings) {
    try {
        GLib.mkdir_with_parents(GLib.path_get_dirname(SETTINGS), 0o700);
        const file = Gio.File.new_for_path(SETTINGS);
        file.replace_contents(new TextEncoder().encode(JSON.stringify(settings)), null, false, Gio.FileCreateFlags.PRIVATE, null);
        file.set_attribute_uint32("unix::mode", 0o600, Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
    } catch (e) {
        logError(e, 'hotch: could not save settings');
    }
}

/// The window closest to its limit: what a glance should show.
function headline(usage) {
    return usage.windows.reduce((best, w) => (!best || w.percent > best.percent ? w : best), null);
}

// MARK: - Indicator

const Indicator = GObject.registerClass(
class HotchIndicator extends PanelMenu.Button {
    _init(extension) {
        super._init(0.5, 'Hotch');
        this._ext = extension;
        this._data = null;
        this._checkedAt = 0;
        this._tab = 'now';
        this._cancellable = new Gio.Cancellable();

        const box = hbox('hotch-panel-box');
        this._panelRing = new Ring('hotch-panel-ring', 2.2);
        this._panelLabel = label('', 'hotch-panel-label');
        this._panelAlert = label('', 'hotch-panel-alert', {visible: false});
        box.add_child(this._panelRing);
        box.add_child(this._panelLabel);
        box.add_child(this._panelAlert);
        this.add_child(box);

        this._card = vbox('hotch-card');
        this._tabs = hbox('hotch-tabs');
        this._tabButtons = {};
        for (const tab of TABS) {
            const button = new St.Button({style_class: 'hotch-tab', x_expand: true, can_focus: true});
            const inner = vbox('hotch-tab-inner');
            inner.add_child(themedIcon(tab.icons, 'hotch-tab-icon'));
            inner.add_child(label(tab.label, 'hotch-tab-label', {x_align: Clutter.ActorAlign.CENTER}));
            button.set_child(inner);
            button.connect('clicked', () => this._show(tab.id));
            this._tabButtons[tab.id] = button;
            this._tabs.add_child(button);
        }
        this._page = vbox('hotch-page');
        this._scroll = new St.ScrollView({style_class: 'hotch-scroll', overlay_scrollbars: true,
            hscrollbar_policy: St.PolicyType.NEVER, vscrollbar_policy: St.PolicyType.AUTOMATIC});
        this._scroll.set_child(this._page);
        this._footer = hbox('hotch-footer');
        this._checkedLabel = label('', 'hotch-footer-label');
        const refresh = new St.Button({style_class: 'hotch-footer-button', can_focus: true});
        refresh.set_child(themedIcon(['view-refresh-symbolic'], 'hotch-footer-icon'));
        refresh.connect('clicked', () => this._refresh());
        this._homeButton = new St.Button({style_class: 'hotch-footer-button hotch-home-button', can_focus: true});
        this._homeButton.connect('clicked', () => this._ext.setHome(this._ext.settings.home === 'panel' ? 'pill' : 'panel'));
        const settings = new St.Button({style_class: 'hotch-footer-button', can_focus: true, accessible_name: 'Settings'});
        settings.set_child(themedIcon(['emblem-system-symbolic'], 'hotch-footer-icon'));
        settings.connect('clicked', () => this._show('settings'));
        this._footer.add_child(this._checkedLabel);
        this._footer.add_child(spacer());
        this._footer.add_child(this._homeButton);
        this._footer.add_child(settings);
        this._footer.add_child(refresh);

        // A quiet footer line while a newer Linux release is out. Hotch only
        // links to it; downloading and installing stay with the user.
        this._updateRow = hbox('hotch-update-row', {visible: false});
        this._updateLabel = label('', 'hotch-footer-label hotch-update-label');
        const updateLink = new St.Button({style_class: 'hotch-footer-button', can_focus: true});
        const updateBox = hbox('hotch-update-link');
        updateBox.add_child(themedIcon(['software-update-available-symbolic'], 'hotch-footer-icon'));
        updateBox.add_child(this._updateLabel);
        updateLink.set_child(updateBox);
        updateLink.connect('clicked', () => this._openRelease(this._notice));
        this._updateSkip = new St.Button({style_class: 'hotch-footer-button', can_focus: true});
        this._updateSkip.set_child(label('Skip this version', 'hotch-footer-label'));
        this._updateSkip.connect('clicked', () => {
            if (this._notice) this._ext.updateSettings({updateSkipped: this._notice.version});
        });
        this._updateRow.add_child(updateLink);
        this._updateRow.add_child(spacer());
        this._updateRow.add_child(this._updateSkip);

        this._card.add_child(this._tabs);
        this._card.add_child(this._scroll);
        this._card.add_child(this._updateRow);
        this._card.add_child(this._footer);
        this.menu.box.add_child(this._card);
        this.watchMenu(this.menu);

        this._render();
        this._refresh();
        this.setRefreshTimer();
    }

    setRefreshTimer() {
        if (this._timer) GLib.source_remove(this._timer);
        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, this._ext.settings.refreshSeconds, () => {
            this._refresh();
            return GLib.SOURCE_CONTINUE;
        });
    }

    /// The card lives in whichever menu is opening: the top bar's or the pill's.
    watchMenu(menu) {
        menu.actor.add_style_class_name('hotch-menu');
        menu.actor.add_style_class_name('hotch-surface');
        // The card is moved in when a menu opens, so a menu without it looks
        // empty and PopupMenu.open() would refuse to open.
        menu.isEmpty = () => false;
        menu.connect('open-state-changed', (_menu, open) => {
            if (!open)
                return;
            if (this._card.get_parent() !== menu.box) {
                this._card.get_parent()?.remove_child(this._card);
                menu.box.add_child(this._card);
            }
            if (now() - this._checkedAt > STALE_SECONDS)
                this._refresh();
            this._render();
        });
    }

    destroy() {
        this._cancellable.cancel();
        this._process?.force_exit();
        this._updateProcess?.force_exit();
        if (this._timer)
            GLib.source_remove(this._timer);
        this._timer = null;
        this._card.destroy();
        super.destroy();
    }

    // MARK: Data

    _binary() {
        const home = GLib.get_home_dir();
        return [GLib.find_program_in_path('hotch'), `${home}/.local/bin/hotch`, `${home}/.cargo/bin/hotch`]
            .find(p => p && GLib.file_test(p, GLib.FileTest.IS_EXECUTABLE));
    }

    _refresh() {
        if (this._busy) {
            this._refreshAgain = true;
            return;
        }
        const bin = this._binary();
        if (!bin) {
            this._data = {missing: true};
            this._render();
            return;
        }
        this._busy = true;
        let proc;
        try {
            proc = Gio.Subprocess.new([bin, 'all', '--json'],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE);
        } catch (e) {
            this._busy = false;
            logError(e, 'hotch: could not start');
            return;
        }
        this._process = proc;
        proc.communicate_utf8_async(null, this._cancellable, (p, res) => {
            this._process = null;
            this._busy = false;
            try {
                const [, out] = p.communicate_utf8_finish(res);
                if (!this._cancellable.is_cancelled()) this._apply(JSON.parse(out));
            } catch (e) {
                if (!e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                    logError(e, 'hotch: refresh failed');
            }
            if (this._refreshAgain && !this._cancellable.is_cancelled()) {
                this._refreshAgain = false;
                this._refresh();
            }
        });
    }

    /// Check now: the answer lands in the cache the next poll reads, so a
    /// failed check (offline, rate-limited) changes nothing on screen.
    _checkForUpdates() {
        const bin = this._binary();
        if (!bin || this._updateProcess)
            return;
        let proc;
        try {
            proc = Gio.Subprocess.new([bin, 'update-check', '--json'],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE);
        } catch (e) {
            logError(e, 'hotch: could not check for updates');
            return;
        }
        this._updateProcess = proc;
        this._render();
        proc.communicate_utf8_async(null, this._cancellable, (p, res) => {
            this._updateProcess = null;
            try {
                p.communicate_utf8_finish(res);
            } catch (e) {
                if (!e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                    logError(e, 'hotch: update check failed');
            }
            if (!this._cancellable.is_cancelled())
                this._refresh();
        });
    }

    _openRelease(release) {
        if (!release)
            return;
        try {
            Gio.AppInfo.launch_default_for_uri(release.url, global.create_app_launch_context(0, -1));
        } catch (e) {
            logError(e, 'hotch: could not open the release page');
        }
        this.menu.close();
        this._ext.pill?.menu.close();
    }

    _apply(fresh) {
        const previous = this._data?.usage ?? [];
        const enabled = this._ext.settings.providers;
        fresh.usage = mergeUsage(fresh.usage.filter(u => enabled.includes(u.provider)), previous, now());
        fresh.sessions = (fresh.sessions ?? []).filter(s => enabled.includes(s.provider));
        this._data = fresh;
        this._checkedAt = now();
        // Usage refresh must not replace text fields while a Focus task or
        // custom duration is being typed. Clock ticks update only the label.
        if (this._tab === 'focus') {
            this._renderPanel();
            this._renderUpdate();
            this._ext.pill?.render(this._data);
            this._checkedLabel.text = 'Last check just now';
        } else {
            this._render();
        }
    }

    // MARK: Rendering

    _show(tab) {
        this._tab = tab;
        this._render();
    }

    _render() {
        this._ext.applyTheme();
        const height = Math.max(160, Math.min(420, (Main.layoutManager.primaryMonitor?.height ?? 900) - Main.panel.height - 160));
        this._scroll.set_style(`max-height: ${height}px;`);
        this._renderPanel();
        this._renderUpdate();
        this._ext.pill?.render(this._data);
        this._homeButton.set_child(label(this._ext.settings.home === 'panel' ? 'Float as pill' : 'Move to top bar',
            'hotch-footer-label hotch-home-label'));
        for (const [id, button] of Object.entries(this._tabButtons)) {
            if (id === this._tab)
                button.add_style_pseudo_class('checked');
            else
                button.remove_style_pseudo_class('checked');
        }
        this._page.destroy_all_children();
        this._focusClock = null;
        this._checkedLabel.text = this._checkedAt ? `Last check ${ago(now() - this._checkedAt)}` : 'Checking…';

        // Preferences, Focus and Clipboard are usable without the Rust binary.
        if (this._tab === 'settings') { this._renderSettings(); return; }
        if (this._tab === 'focus') { this._renderFocus(); return; }
        if (this._tab === 'clipboard') { this._renderClipboard(); return; }
        if (!this._data) {
            this._page.add_child(label('Reading usage…', 'hotch-muted hotch-empty'));
            return;
        }
        if (this._data.missing) {
            const tile = vbox('hotch-tile');
            tile.add_child(label('hotch is not installed', 'hotch-title'));
            tile.add_child(label('Build it from the linux folder and put it in ~/.local/bin.',
                'hotch-sub', {style: 'max-width: 300px;'}));
            this._page.add_child(tile);
            return;
        }
        ({now: this._renderNow, ai: this._renderAI, sessions: this._renderSessions,
            system: this._renderSystem})[this._tab].call(this);
    }

    _renderPanel() {
        const usages = this._data?.usage?.filter(u => u.windows.length) ?? [];
        const top = usages.map(u => ({u, w: headline(u)})).sort((a, b) => b.w.percent - a.w.percent)[0];
        if (top) {
            const brand = BRANDS[top.u.provider] ?? BRANDS.claude;
            this._panelRing.setValue(top.w.percent, brand.accent, brand.highlight, true, this._remaining());
            this._panelLabel.text = `${this._percent(top.w.percent)}%`;
        } else {
            this._panelRing.setValue(null, BRANDS.claude.accent);
            this._panelLabel.text = '';
        }
        const needs = (this._data?.sessions ?? []).filter(s => s.activity === 'needs input').length;
        this._panelAlert.visible = needs > 0;
        this._panelAlert.text = `● ${needs}`;
        if (this._ext.settings.focus.startedAt !== null)
            this._panelLabel.text += ` · ${clockText(focusReading(this._ext.settings.focus, now()).seconds)}`;
    }

    _renderUpdate() {
        this._notice = updateNotice(this._data?.update, this._ext.settings);
        this._updateRow.visible = Boolean(this._notice);
        this._updateLabel.text = this._notice ? `Hotch ${this._notice.version} is available` : '';
    }

    _remaining() { return this._ext.settings.displayMode === 'remaining'; }
    _percent(used) { return Math.round(displayedPercent(used, this._ext.settings.displayMode)); }

    _usages() {
        return (this._data.usage ?? []).filter(u => u.windows.length || !/not installed/.test(u.error ?? ''));
    }

    _renderNow() {
        const sessions = this._data.sessions ?? [];
        const waiting = sessions.find(s => s.activity === 'needs input');
        if (waiting) {
            const tile = hbox('hotch-tile hotch-attention');
            tile.add_child(themedIcon(['hand-open-symbolic', 'dialog-warning-symbolic'], 'hotch-attention-icon'));
            const text = vbox('hotch-text');
            text.add_child(label('Needs your attention', 'hotch-attention-kicker'));
            text.add_child(label(waiting.name, 'hotch-title'));
            text.add_child(label(waiting.project ? `${waiting.project} · needs you` : 'needs you', 'hotch-sub'));
            tile.add_child(text);
            this._page.add_child(this._link(tile, 'sessions'));
        }

        const counts = {};
        for (const s of sessions)
            counts[s.activity] = (counts[s.activity] ?? 0) + 1;
        const parts = [['working', 'working'], ['shell', 'in shell'], ['needs input', 'need you'], ['waiting', 'idle']]
            .filter(([k]) => counts[k]).map(([k, word]) => `${counts[k]} ${word}`);
        const row = hbox('hotch-row');
        row.add_child(themedIcon(['utilities-terminal-symbolic'], 'hotch-row-icon'));
        row.add_child(label(parts.length ? parts.join(' · ') : 'No active sessions', 'hotch-row-label'));
        row.add_child(spacer());
        row.add_child(themedIcon(['go-next-symbolic', 'pan-end-symbolic'], 'hotch-chevron'));
        this._page.add_child(this._link(row, 'sessions'));

        const usages = this._usages();
        if (usages.length) {
            this._page.add_child(label('AI CAPACITY', 'hotch-section'));
            const tile = vbox('hotch-tile hotch-tile-list');
            usages.forEach((u, i) => {
                if (i > 0)
                    tile.add_child(new St.Widget({style_class: 'hotch-divider'}));
                tile.add_child(this._providerRow(u));
            });
            this._page.add_child(this._link(tile, 'ai'));
        }

        const sys = this._data.system ?? {};
        const memPercent = sys.memTotalGB ? 100 * sys.memUsedGB / sys.memTotalGB : 0;
        const hot = (sys.cpuPercent ?? 0) >= 80 || memPercent >= 85;
        const sysTile = hbox(`hotch-tile ${hot ? 'hotch-hot' : ''}`);
        sysTile.add_child(themedIcon([hot ? 'dialog-warning-symbolic' : 'computer-symbolic'], 'hotch-tile-icon'));
        const text = vbox('hotch-text');
        text.add_child(label(hot ? 'Your computer is running hot' : 'This computer', hot ? 'hotch-hot-title' : 'hotch-title'));
        text.add_child(label(this._systemLine(), 'hotch-sub'));
        sysTile.add_child(text);
        sysTile.add_child(spacer());
        sysTile.add_child(themedIcon(['go-next-symbolic', 'pan-end-symbolic'], 'hotch-chevron'));
        this._page.add_child(this._link(sysTile, 'system'));
    }

    _providerRow(u) {
        const brand = BRANDS[u.provider] ?? {name: u.provider, accent: [0.78, 0.78, 0.8]};
        const w = headline(u);
        const row = hbox('hotch-provider-row');
        row.add_child(this._markedRing(u.provider, w?.percent ?? null));
        const text = vbox('hotch-text', {x_expand: true});
        const titleRow = hbox('');
        titleRow.add_child(label(brand.name, 'hotch-title'));
        titleRow.add_child(spacer());
        if (w)
            titleRow.add_child(label(`${this._percent(w.percent)}% ${this._ext.settings.displayMode}`, 'hotch-percent'));
        text.add_child(titleRow);
        if (w) {
            const reset = w.resetsAt ? ` · Resets ${relative(w.resetsAt - now())}` : '';
            text.add_child(label(`${w.label}${reset}`, 'hotch-sub'));
        } else {
            text.add_child(label(u.error ?? u.extras?.[0] ?? 'No reading', 'hotch-sub'));
        }
        if (u.plan)
            text.add_child(label(`${u.plan} plan`, 'hotch-muted'));
        if (u.stale)
            text.add_child(label(readingStatus(u, now()), 'hotch-sub'));
        row.add_child(text);
        return row;
    }

    /// The Now page's provider ring: the brand mark sits inside the gauge.
    _markedRing(provider, percent) {
        const brand = BRANDS[provider] ?? {accent: [0.78, 0.78, 0.8]};
        const stack = new St.Widget({layout_manager: new Clutter.BinLayout(), y_align: Clutter.ActorAlign.CENTER});
        const ring = new Ring('hotch-ring', 3.5);
        ring.setValue(percent, brand.accent, brand.highlight, true, this._remaining());
        stack.add_child(ring);
        const mark = markIcon(this._ext.dir, provider, 'hotch-ring-mark');
        if (mark) {
            mark.x_align = Clutter.ActorAlign.CENTER;
            stack.add_child(mark);
        }
        return stack;
    }

    _renderAI() {
        const usages = this._usages();
        if (!usages.length) {
            this._page.add_child(label('No AI providers found. Install and sign in to Claude Code or Codex.',
                'hotch-muted hotch-empty'));
            return;
        }
        for (const u of usages) {
            const brand = BRANDS[u.provider] ?? {name: u.provider, accent: [0.78, 0.78, 0.8]};
            const tile = vbox('hotch-tile hotch-tile-list');
            const head = hbox('hotch-provider-head');
            const mark = markIcon(this._ext.dir, u.provider, 'hotch-head-mark');
            if (mark)
                head.add_child(mark);
            head.add_child(label(brand.name, 'hotch-title'));
            tile.add_child(head);
            if (!u.windows.length)
                tile.add_child(label(u.error ?? 'No reading', 'hotch-sub'));
            for (const w of u.windows) {
                const row = hbox('hotch-window-row');
                const ring = new Ring('hotch-ring', 3.5);
                ring.setValue(w.percent, brand.accent, brand.highlight, true, this._remaining());
                row.add_child(ring);
                const text = vbox('hotch-text', {x_expand: true});
                const top = hbox('');
                top.add_child(label(w.label, 'hotch-window-label'));
                top.add_child(spacer());
                top.add_child(label(`${this._percent(w.percent)}% ${this._ext.settings.displayMode}`, 'hotch-percent'));
                text.add_child(top);
                if (w.resetsAt)
                    text.add_child(label(`Resets ${relative(w.resetsAt - now())}`, 'hotch-sub'));
                row.add_child(text);
                tile.add_child(row);
            }
            for (const extra of u.extras ?? [])
                tile.add_child(label(extra, 'hotch-muted'));
            if (u.plan)
                tile.add_child(label(`${u.plan} plan`, 'hotch-muted'));
            if (u.stale)
                tile.add_child(label(readingStatus(u, now()), 'hotch-sub'));
            this._page.add_child(tile);
        }
    }

    _renderSessions() {
        const sessions = this._data.sessions ?? [];
        if (!sessions.length) {
            this._page.add_child(label('No active sessions', 'hotch-muted hotch-empty'));
            return;
        }
        const tile = vbox('hotch-tile hotch-tile-list');
        sessions.forEach((s, i) => {
            if (i > 0)
                tile.add_child(new St.Widget({style_class: 'hotch-divider'}));
            const row = hbox('hotch-session-row');
            const mark = markIcon(this._ext.dir, s.provider, 'hotch-head-mark');
            if (mark)
                row.add_child(mark);
            const text = vbox('hotch-text', {x_expand: true});
            text.add_child(label(s.name, 'hotch-title'));
            const where = s.project ? `${s.project} · ` : '';
            text.add_child(label(`${where}${ago(now() - s.lastEventAt)}`, 'hotch-sub'));
            row.add_child(text);
            const state = s.activity.replace(' ', '-');
            row.add_child(label(statusWord(s), `hotch-state hotch-state-${state}`));
            tile.add_child(row);
        });
        this._page.add_child(tile);
    }

    _renderSystem() {
        const sys = this._data.system ?? {};
        if (sys.error) {
            this._page.add_child(label(sys.error, 'hotch-muted hotch-empty'));
            return;
        }
        const tile = vbox('hotch-tile hotch-tile-list');
        const add = (name, percent, color, detail) => {
            const row = hbox('hotch-window-row');
            const ring = new Ring('hotch-ring', 3.5);
            ring.setValue(percent, color, null, false);
            row.add_child(ring);
            const text = vbox('hotch-text', {x_expand: true});
            const top = hbox('');
            top.add_child(label(name, 'hotch-window-label'));
            top.add_child(spacer());
            top.add_child(label(percent === null ? '—' : `${Math.round(percent)}%`, 'hotch-percent'));
            text.add_child(top);
            if (detail)
                text.add_child(label(detail, 'hotch-sub'));
            row.add_child(text);
            tile.add_child(row);
        };
        add('CPU', sys.cpuPercent ?? null, CPU, 'All cores');
        const mem = sys.memTotalGB ? 100 * sys.memUsedGB / sys.memTotalGB : null;
        add('Memory', mem, MEMORY, `${(sys.memUsedGB ?? 0).toFixed(1)} of ${Math.round(sys.memTotalGB ?? 0)} GB`);
        if (sys.battery)
            add('Battery', sys.battery.percent, POWER, sys.battery.status);
        this._page.add_child(tile);
    }

    _action(text, callback) {
        const button = new St.Button({style_class: 'hotch-action', can_focus: true, label: text});
        button.connect('clicked', callback);
        return button;
    }

    _paragraph(text) {
        const actor = label(text, 'hotch-muted hotch-paragraph');
        actor.clutter_text.line_wrap = true;
        return actor;
    }

    _choice(title, options, current, callback) {
        this._page.add_child(label(title, 'hotch-section'));
        for (let i = 0; i < options.length; i += 3) {
            const row = hbox('hotch-choices');
            for (const [value, text] of options.slice(i, i + 3)) {
                const button = this._action(text, () => callback(value));
                button.x_expand = true;
                if (value === current) button.add_style_pseudo_class('checked');
                row.add_child(button);
            }
            this._page.add_child(row);
        }
    }

    _renderSettings() {
        const s = this._ext.settings;
        this._page.add_child(label('Settings', 'hotch-title'));
        this._choice('HOME', HOMES, s.home, home => this._ext.setHome(home));
        this._choice('APPEARANCE', [['system', 'System'], ['dark', 'Dark'], ['light', 'Light']], s.theme,
            theme => this._ext.updateSettings({theme}));
        this._choice('USAGE DISPLAY', [['used', 'Used'], ['remaining', 'Remaining']], s.displayMode,
            displayMode => this._ext.updateSettings({displayMode}));
        this._choice('REFRESH', [[30, '30 seconds'], [60, '1 minute'], [120, '2 minutes'], [300, '5 minutes']], s.refreshSeconds,
            refreshSeconds => this._ext.updateSettings({refreshSeconds}));
        this._page.add_child(label('PROVIDERS', 'hotch-section'));
        for (const id of ['claude', 'codex']) {
            const enabled = s.providers.includes(id);
            this._page.add_child(this._action(`${enabled ? '✓' : '○'} ${BRANDS[id].name}`, () => {
                const providers = enabled ? s.providers.filter(p => p !== id) : [...s.providers, id];
                this._ext.updateSettings({providers}, true);
            }));
            const u = this._data?.usage?.find(item => item.provider === id);
            const help = id === 'claude' ? 'Install Claude Code and run claude auth login in a terminal.'
                : 'Install the Codex CLI and run codex login in a terminal.';
            this._page.add_child(this._paragraph(enabled ? (u?.error ?? (u?.windows.length ? 'Connected' : help)) : 'Disabled — Hotch will not read this provider.'));
        }
        this._page.add_child(label('CLIPBOARD', 'hotch-section'));
        this._page.add_child(this._action(s.clipboardEnabled ? 'Disable clipboard history' : 'Enable clipboard history',
            () => this._ext.updateSettings({clipboardEnabled: !s.clipboardEnabled})));
        this._page.add_child(this._paragraph('Optional text history: five entries in memory, cleared when disabled or Hotch stops. Password-manager privacy markers are skipped when supplied.'));
        this._renderUpdateSettings();
        this._page.add_child(this._paragraph(`Hotch ${this._ext.metadata['version-name']} · Experimental Linux support. The GNOME extension starts at login while enabled. Other desktops use the tray and hotch settings CLI.`));
        this._page.add_child(this._paragraph('Notch, Dock integration, Backpack, additional providers and advanced hardware readings remain unavailable on Linux.'));
    }

    _renderUpdateSettings() {
        const s = this._ext.settings;
        const u = this._data?.update;
        // The release a check found, shown here even with automatic checks off.
        const release = updateNotice(u, {...s, updateChecks: true});
        const skipped = Boolean(u?.latest) && u.latest === s.updateSkipped && u.latest !== u.current;
        let status = 'Not checked yet';
        if (this._updateProcess)
            status = 'Checking GitHub…';
        else if (release)
            status = `Hotch ${release.version} is available`;
        else if (skipped)
            status = `Skipping Hotch ${u.latest}`;
        else if (u?.checkedAt)
            status = `Hotch ${u.current} is up to date · checked ${ago(now() - u.checkedAt)}`;
        this._page.add_child(label('UPDATES', 'hotch-section'));
        this._page.add_child(this._action(`${s.updateChecks ? '✓' : '○'} Check for updates daily`,
            () => this._ext.updateSettings({updateChecks: !s.updateChecks}, true)));
        this._page.add_child(this._paragraph(status));
        const actions = hbox('hotch-choices');
        actions.add_child(this._action('Check now', () => this._checkForUpdates()));
        if (release)
            actions.add_child(this._action('Open release page', () => this._openRelease(release)));
        if (skipped)
            actions.add_child(this._action('Show again', () => this._ext.updateSettings({updateSkipped: ''}, true)));
        this._page.add_child(actions);
        this._page.add_child(this._paragraph('Once a day Hotch asks GitHub which Linux release is newest, sending its version and nothing about you. It never downloads or installs an update.'));
    }

    _renderFocus() {
        const f = this._ext.settings.focus;
        const reading = focusReading(f, now());
        this._page.add_child(label('Focus', 'hotch-title'));
        this._focusClock = label(clockText(reading.seconds), 'hotch-focus-clock');
        this._page.add_child(this._focusClock);
        this._page.add_child(label(reading.done ? 'Timer complete' : f.startedAt !== null ? 'Running' : f.elapsed ? 'Paused' : 'Ready', 'hotch-sub'));
        const title = new St.Entry({style_class: 'hotch-entry', hint_text: 'What are you working on?', can_focus: true, text: f.title});
        this._page.add_child(title);
        let minutes;
        if (f.elapsed === 0 && f.startedAt === null) {
            this._choice('MODE', [['timer', 'Timer'], ['stopwatch', 'Stopwatch']], f.mode,
                mode => this._ext.updateSettings({focus: {...f, mode, title: title.get_text()}}));
            if (f.mode === 'timer') {
                this._choice('DURATION', [[900, '15 min'], [1500, '25 min'], [3000, '50 min']], f.duration,
                    duration => this._ext.updateSettings({focus: {...f, duration, title: title.get_text()}}));
                minutes = new St.Entry({style_class: 'hotch-entry', hint_text: 'Custom minutes (1–1440)',
                    can_focus: true, text: String(f.duration / 60)});
                this._page.add_child(minutes);
            }
        }
        const error = label('', 'hotch-sub');
        const controls = hbox('hotch-choices');
        controls.add_child(this._action(f.startedAt !== null ? 'Pause' : f.elapsed && !reading.done ? 'Resume' : 'Start', () => {
            let state = {...f, title: title.get_text()};
            if (minutes) {
                const input = minutes.get_text().trim();
                const n = Number(input);
                if (!/^\d+$/.test(input) || n < 1 || n > 1440) {
                    error.text = 'Enter a whole number from 1 to 1440 minutes.';
                    return;
                }
                state.duration = n * 60;
            }
            state = focusAction(state, f.startedAt !== null ? 'pause' : 'start', now());
            this._ext.updateSettings({focus: state});
        }));
        controls.add_child(this._action('Reset', () => this._ext.updateSettings({focus: focusAction({...f, title: title.get_text()}, 'reset', now())})));
        this._page.add_child(controls);
        this._page.add_child(error);
        this._page.add_child(this._paragraph('The clock stays on your companion while running. Timer state survives a GNOME restart; completion sends one desktop notification.'));
    }

    _renderClipboard() {
        this._page.add_child(label('Clipboard', 'hotch-title'));
        if (!this._ext.settings.clipboardEnabled) {
            this._page.add_child(this._paragraph('Clipboard history is off. Enable it to remember future text copies in memory. Applications must supply privacy markers for Hotch to recognise sensitive copies.'));
            this._page.add_child(this._action('Enable clipboard history', () => this._ext.updateSettings({clipboardEnabled: true})));
            return;
        }
        for (const text of this._ext.clipboardItems) {
            const preview = text.replace(/\s+/g, ' ').slice(0, 100);
            this._page.add_child(this._action(preview, () => this._ext.copyClipboard(text)));
        }
        if (!this._ext.clipboardItems.length)
            this._page.add_child(this._paragraph('Future text copies will appear here. Select an entry to copy it again.'));
        this._page.add_child(this._action('Clear history', () => this._ext.clearClipboard()));
        this._page.add_child(this._action('Disable and clear', () => this._ext.updateSettings({clipboardEnabled: false})));
    }

    _systemLine() {
        const sys = this._data.system ?? {};
        if (sys.error)
            return sys.error;
        const parts = [];
        if (sys.cpuPercent !== null && sys.cpuPercent !== undefined)
            parts.push(`CPU ${Math.round(sys.cpuPercent)}%`);
        if (sys.memTotalGB)
            parts.push(`Memory ${Math.round(100 * sys.memUsedGB / sys.memTotalGB)}%`);
        if (sys.battery)
            parts.push(`Battery ${sys.battery.percent}%`);
        return parts.join(' · ');
    }

    /// Wraps a tile so a click opens the matching tab, like the Mac overview.
    _link(child, tab) {
        child.x_expand = true;
        child.x_align = Clutter.ActorAlign.FILL;
        const button = new St.Button({
            style_class: 'hotch-link', x_expand: true, x_align: Clutter.ActorAlign.FILL, can_focus: true, child,
        });
        button.connect('clicked', () => this._show(tab));
        return button;
    }
});

// MARK: - Floating pill

/// The floating pill home: a two-line glance that stays on the desktop above
/// windows, drags anywhere, and opens the same card on click.
const Pill = GObject.registerClass(
class HotchPill extends St.BoxLayout {
    _init(extension) {
        super._init({
            style_class: 'hotch-pill',
            orientation: Clutter.Orientation.VERTICAL,
            reactive: true,
            track_hover: true,
            can_focus: true,
        });
        this._ext = extension;
        this._top = hbox('hotch-pill-row');
        this._divider = new St.Widget({style_class: 'hotch-pill-divider'});
        this._bottom = hbox('hotch-pill-row');
        this.add_child(this._top);
        this.add_child(this._divider);
        this.add_child(this._bottom);

        this.menu = new PopupMenu.PopupMenu(this, 0.5, St.Side.TOP);
        Main.uiGroup.add_child(this.menu.actor);
        this.menu.actor.hide();
        this._manager = new PopupMenu.PopupMenuManager(this);
        this._manager.addMenu(this.menu);
    }

    destroy() {
        // The shared card may still sit in this menu ("Move to top bar" is
        // clicked from it): take it out so it outlives the pill.
        this._grab?.dismiss();
        this._grab = null;
        this._press = null;
        this.menu.box.remove_all_children();
        this.menu.destroy();
        super.destroy();
    }

    render(data) {
        this._top.destroy_all_children();
        this._bottom.destroy_all_children();
        const sep = () => new St.Widget({style_class: 'hotch-pill-sep', y_align: Clutter.ActorAlign.CENTER});

        const usages = data?.usage?.filter(u => u.windows.length) ?? [];
        const top = usages.map(u => ({u, w: headline(u)})).sort((a, b) => b.w.percent - a.w.percent)[0];
        const s = this._ext.settings;
        const percent = used => Math.round(displayedPercent(used, s.displayMode));
        const focus = s.focus.startedAt !== null ? clockText(focusReading(s.focus, now()).seconds) : null;
        this.accessible_name = `Hotch${top ? `, ${percent(top.w.percent)} percent ${s.displayMode}` : ''}${focus ? `, Focus ${focus}` : ''}`;
        if (s.home !== 'pill') {
            const vertical = s.home === 'orb' || s.home === 'edge-left' || s.home === 'edge-right';
            this._top.orientation = vertical ? Clutter.Orientation.VERTICAL : Clutter.Orientation.HORIZONTAL;
            if (s.home === 'orb') {
                const ring = new Ring('hotch-orb-ring', 3);
                ring.setValue(top?.w.percent ?? null, top ? BRANDS[top.u.provider].accent : CPU,
                    null, true, s.displayMode === 'remaining');
                this._top.add_child(ring);
            }
            this._top.add_child(label(top ? `${percent(top.w.percent)}%` : 'Hotch', 'hotch-pill-value'));
            if (s.home !== 'orb') {
                const sys = data?.system;
                this._top.add_child(label(sys?.cpuPercent == null ? 'CPU —' : `CPU ${Math.round(sys.cpuPercent)}%`, 'hotch-pill-key'));
                this._top.add_child(label(sys?.memTotalGB ? `Mem ${Math.round(100 * sys.memUsedGB / sys.memTotalGB)}%` : 'Mem —', 'hotch-pill-key'));
            }
            const needs = data?.sessions?.filter(item => item.activity === 'needs input').length ?? 0;
            if (needs) this._top.add_child(label(`● ${needs}`, 'hotch-pill-alert'));
            if (focus) this._top.add_child(label(focus, 'hotch-pill-value'));
            this._divider.visible = this._bottom.visible = false;
            this.place(this.x, this.y);
            return;
        }
        if (top) {
            const mark = markIcon(this._ext.dir, top.u.provider, 'hotch-pill-mark');
            if (mark)
                this._top.add_child(mark);
            const critical = top.w.percent >= CRITICAL_PERCENT ? ' hotch-pill-critical' : '';
            this._top.add_child(label(`${percent(top.w.percent)}%`, `hotch-pill-value${critical}`));
        } else {
            this._top.add_child(label('Hotch', 'hotch-pill-value'));
        }

        const sessions = data?.sessions ?? [];
        const needs = sessions.filter(s => s.activity === 'needs input');
        if (needs.length) {
            this._top.add_child(sep());
            this._top.add_child(label(`● ${needs.length} need${needs.length === 1 ? 's' : ''} you`, 'hotch-pill-alert'));
        }

        const sys = data?.system;
        if (sys?.memTotalGB) {
            this._top.add_child(sep());
            this._top.add_child(label('Mem', 'hotch-pill-key'));
            this._top.add_child(label(`${Math.round(100 * sys.memUsedGB / sys.memTotalGB)}%`, 'hotch-pill-value'));
        }

        // The second line is the session worth a glance: one waiting on you,
        // else one at work.
        if (focus) {
            this._top.add_child(sep());
            this._top.add_child(label(focus, 'hotch-pill-value'));
        }
        const session = needs[0] ?? sessions.find(item => item.activity === 'working');
        this._divider.visible = this._bottom.visible = Boolean(session);
        if (session) {
            const mark = markIcon(this._ext.dir, session.provider, 'hotch-pill-mark-small');
            if (mark)
                this._bottom.add_child(mark);
            this._bottom.add_child(label(session.name, 'hotch-pill-session'));
            const tone = session.activity === 'needs input' ? 'hotch-pill-alert' : `hotch-pill-working-${session.provider}`;
            this._bottom.add_child(label(`● ${statusWord(session)}`, tone));
        }
        this.place(this.x, this.y);
    }

    vfunc_key_press_event(event) {
        if ([Clutter.KEY_Return, Clutter.KEY_space].includes(event.get_key_symbol())) {
            this.menu.toggle();
            return Clutter.EVENT_STOP;
        }
        return Clutter.EVENT_PROPAGATE;
    }

    vfunc_button_press_event(event) {
        if (event.get_button() !== Clutter.BUTTON_PRIMARY)
            return Clutter.EVENT_PROPAGATE;
        const [x, y] = event.get_coords();
        this._press = {x, y, ax: this.x, ay: this.y, moved: false};
        this._grab = global.stage.grab(this);
        return Clutter.EVENT_STOP;
    }

    vfunc_motion_event(event) {
        if (!this._press)
            return Clutter.EVENT_PROPAGATE;
        const [x, y] = event.get_coords();
        const dx = x - this._press.x, dy = y - this._press.y;
        if (!this._press.moved && Math.hypot(dx, dy) < 5)
            return Clutter.EVENT_STOP;
        this._press.moved = true;
        this.menu.close();
        this.place(this._press.ax + dx, this._press.ay + dy);
        return Clutter.EVENT_STOP;
    }

    vfunc_button_release_event(event) {
        if (!this._press || event.get_button() !== Clutter.BUTTON_PRIMARY)
            return Clutter.EVENT_PROPAGATE;
        this._grab?.dismiss();
        this._grab = null;
        const {moved} = this._press;
        this._press = null;
        if (moved) {
            this._ext.savePillPosition(this.x, this.y);
        } else {
            // The box pointer flips upwards on its own when the pill sits low.
            this.menu.toggle();
        }
        return Clutter.EVENT_STOP;
    }

    /// Keeps the pill whole on its monitor.
    place(x, y) {
        const home = this._ext.settings.home;
        const monitor = !home.startsWith('edge-') && Main.layoutManager.monitors.find(m =>
            x >= m.x && x < m.x + m.width && y >= m.y && y < m.y + m.height) || Main.layoutManager.primaryMonitor;
        const [, w] = this.get_preferred_width(-1);
        const [, h] = this.get_preferred_height(w);
        this.set_position(...companionPosition(home, monitor, w, h, x, y, Main.panel.height));
    }
});

export default class HotchExtension extends Extension {
    enable() {
        this._enabled = true;
        this.settings = loadSettings();
        this.clipboardItems = [];
        this._clipboardGeneration = 0;
        this._desktopSettings = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
        this._themeSignal = this._desktopSettings.connect('changed::color-scheme', () => this.applyTheme());
        this._monitorSignal = Main.layoutManager.connect('monitors-changed', () => {
            this.pill?.place(this.pill.x, this.pill.y);
        });
        this._indicator = new Indicator(this);
        Main.panel.addToStatusArea(this.uuid, this._indicator);
        this.setHome(this.settings.home, false);
        this._syncClipboard();
        this._syncFocusTimer();
        GLib.mkdir_with_parents(GLib.path_get_dirname(SETTINGS), 0o700);
        this._settingsMonitor = Gio.File.new_for_path(GLib.path_get_dirname(SETTINGS))
            .monitor_directory(Gio.FileMonitorFlags.WATCH_MOVES, null);
        this._settingsMonitor.connect('changed', (_monitor, file, other) => {
            if (file?.get_path() !== SETTINGS && other?.get_path() !== SETTINGS) return;
            if (this._settingsReload) GLib.source_remove(this._settingsReload);
            this._settingsReload = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 150, () => {
                this._settingsReload = null;
                const fresh = loadSettings();
                if (JSON.stringify(fresh) !== JSON.stringify(this.settings)) this._applySettings(fresh, true);
                return GLib.SOURCE_REMOVE;
            });
        });
        const preview = GLib.getenv('HOTCH_PREVIEW');
        if (preview) this._preview(preview);
    }

    updateSettings(patch, refresh = false) {
        const fresh = normalizeSettings({...this.settings, ...patch});
        saveSettings(fresh);
        this._applySettings(fresh, refresh);
    }

    _applySettings(fresh, refresh) {
        const oldHome = this.settings.home;
        const oldProviders = this.settings.providers.join(',');
        this.settings = fresh;
        if (oldHome !== fresh.home) this.setHome(fresh.home, false);
        this._indicator.setRefreshTimer();
        this._syncClipboard();
        this._syncFocusTimer();
        if (this._indicator._data) {
            this._indicator._data.usage = (this._indicator._data.usage ?? []).filter(u => fresh.providers.includes(u.provider));
            this._indicator._data.sessions = (this._indicator._data.sessions ?? []).filter(u => fresh.providers.includes(u.provider));
        }
        this._indicator._render();
        if (refresh || oldProviders !== fresh.providers.join(',')) this._indicator._refresh();
    }

    applyTheme() {
        const light = this.settings.theme === 'light' || this.settings.theme === 'system' &&
            this._desktopSettings?.get_string('color-scheme') !== 'prefer-dark';
        for (const actor of [this._indicator?.menu.actor, this.pill?.menu.actor, this.pill]) {
            if (!actor) continue;
            if (light) actor.add_style_class_name('hotch-light');
            else actor.remove_style_class_name('hotch-light');
        }
    }

    _syncFocusTimer() {
        if (this.settings.focus.startedAt === null) {
            if (this._focusTimer) GLib.source_remove(this._focusTimer);
            this._focusTimer = null;
        } else if (!this._focusTimer) {
            this._focusTimer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 1, () => {
                const reading = focusReading(this.settings.focus, now());
                if (reading.done) {
                    this._focusTimer = null;
                    this.updateSettings({focus: focusAction(this.settings.focus, 'complete', now())});
                    Main.notify('Hotch', 'Focus timer complete');
                    return GLib.SOURCE_REMOVE;
                }
                this._indicator._renderPanel();
                this.pill?.render(this._indicator._data);
                if (this._indicator._focusClock) this._indicator._focusClock.text = clockText(reading.seconds);
                return GLib.SOURCE_CONTINUE;
            });
        }
    }

    _syncClipboard() {
        if (!this.settings.clipboardEnabled) {
            if (this._selectionSignal) this._selection.disconnect(this._selectionSignal);
            this._selectionSignal = null;
            this._selection = null;
            this.clipboardItems = [];
            this._clipboardGeneration++;
        } else if (!this._selectionSignal) {
            this._selection = global.display.get_selection();
            // Only future copy events are collected. Primary selection is ignored.
            this._selectionSignal = this._selection.connect('owner-changed', (_selection, type) => {
                if (type !== Meta.SelectionType.SELECTION_CLIPBOARD) return;
                const generation = ++this._clipboardGeneration;
                const clipboard = St.Clipboard.get_default();
                if (privateClipboard(clipboard.get_mimetypes(St.ClipboardType.CLIPBOARD))) return;
                clipboard.get_text(St.ClipboardType.CLIPBOARD, (_clipboard, text) => {
                    if (!this._enabled || !this.settings.clipboardEnabled || generation !== this._clipboardGeneration) return;
                    if (privateClipboard(clipboard.get_mimetypes(St.ClipboardType.CLIPBOARD))) return;
                    this.clipboardItems = rememberClipboard(this.clipboardItems, text);
                    if (this._indicator._tab === 'clipboard') this._indicator._render();
                });
            });
        }
    }

    copyClipboard(text) {
        this.clipboardItems = rememberClipboard(this.clipboardItems, text);
        St.Clipboard.get_default().set_text(St.ClipboardType.CLIPBOARD, text);
        this._indicator.menu.close();
        this.pill?.menu.close();
    }

    clearClipboard() {
        this._clipboardGeneration++;
        this.clipboardItems = [];
        this._indicator._render();
    }

    /// Development only: with HOTCH_PREVIEW=/path/prefix (set when running a
    /// nested `gnome-shell --devkit`), open each tab once the data is in and
    /// save the screen to <prefix>-<tab>.png, since a screenshot tool cannot
    /// run while the menu holds the grab.
    async _preview(prefix) {
        const wait = ms => new Promise(r => GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => r() ?? GLib.SOURCE_REMOVE));
        await wait(Number(GLib.getenv('HOTCH_PREVIEW_DELAY') ?? 8000));
        for (const tab of [...TABS, {id: 'settings'}]) {
            this._indicator.menu.open();
            this._indicator._show(tab.id);
            await wait(600);
            await this._shoot(`${prefix}-${tab.id}.png`);
        }
        this._indicator.menu.close();
        this.setHome('pill', false);
        await wait(600);
        await this._shoot(`${prefix}-pill.png`);
        this.pill.menu.open();
        await wait(600);
        await this._shoot(`${prefix}-pill-menu.png`);
        this.pill.menu.close();
        // Back to the top bar from the pill's card, then a refresh: the card
        // must survive the pill.
        this.setHome('panel', false);
        this._indicator._refresh();
        await wait(3000);
        this._indicator.menu.open();
        await wait(600);
        await this._shoot(`${prefix}-back.png`);
        this._indicator.menu.close();
    }

    /// The hidden top-bar button owns the shared card for every companion.
    setHome(home, save = true) {
        if (!HOMES.some(([id]) => id === home)) home = 'panel';
        this.settings.home = home;
        if (save) saveSettings(this.settings);
        this._indicator.menu.close();
        if (this.pill) {
            Main.layoutManager.removeChrome(this.pill);
            this.pill.destroy();
            this.pill = null;
        }
        this._indicator.container.visible = home === 'panel';
        if (home !== 'panel') {
            this.pill = new Pill(this);
            this.pill.add_style_class_name(home === 'orb' ? 'hotch-orb' : home.startsWith('edge-') ? `hotch-edge hotch-${home}` : 'hotch-floating');
            this._indicator.watchMenu(this.pill.menu);
            Main.layoutManager.addChrome(this.pill, {trackFullscreen: true});
            this.pill.render(this._indicator._data);
            const monitor = Main.layoutManager.primaryMonitor;
            const [, w] = this.pill.get_preferred_width(-1);
            this.pill.place(this.settings.pillX ?? monitor.x + monitor.width - w - 24,
                this.settings.pillY ?? monitor.y + Main.panel.height + 16);
        }
        this._indicator._render();
    }

    savePillPosition(x, y) {
        if (this.settings.home.startsWith('edge-')) return;
        Object.assign(this.settings, {pillX: x, pillY: y});
        saveSettings(this.settings);
    }

    _shoot(path) {
        const stream = Gio.File.new_for_path(path).replace(null, false, Gio.FileCreateFlags.NONE, null);
        return new Promise(resolve => new Shell.Screenshot().screenshot(false, stream, (shot, res) => {
            try {
                shot.screenshot_finish(res);
            } catch (e) {
                logError(e, 'hotch: preview');
            }
            stream.close(null);
            resolve();
        }));
    }

    disable() {
        this._enabled = false;
        this._clipboardGeneration++;
        if (this._selectionSignal) this._selection.disconnect(this._selectionSignal);
        this._selectionSignal = null;
        this._selection = null;
        this.clipboardItems = [];
        if (this._focusTimer) GLib.source_remove(this._focusTimer);
        this._focusTimer = null;
        if (this._settingsReload) GLib.source_remove(this._settingsReload);
        this._settingsReload = null;
        this._settingsMonitor?.cancel();
        this._settingsMonitor = null;
        if (this._themeSignal) this._desktopSettings.disconnect(this._themeSignal);
        this._themeSignal = null;
        this._desktopSettings = null;
        if (this._monitorSignal) Main.layoutManager.disconnect(this._monitorSignal);
        this._monitorSignal = null;
        if (this.pill) {
            Main.layoutManager.removeChrome(this.pill);
            this.pill.destroy();
            this.pill = null;
        }
        this._indicator?.destroy();
        this._indicator = null;
        this.settings = null;
    }
}
