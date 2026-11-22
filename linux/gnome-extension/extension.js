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
    clockText, focusRun, quickFocus, sessionSummary, systemAlerts, systemWarning,
    privateClipboard, rememberClipboard, companionPosition} from './model.js';

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

// The card's four tabs, as on the Mac (PanelPage), where the system tab is
// called Mac. Home draws the Hotch mark rather than a themed icon; Desk takes
// Focus's clock, since clipboard history is off until switched on.
const TABS = [
    {id: 'home', title: 'Hotch'},
    {id: 'ai', title: 'AI', icons: ['starred-symbolic']},
    {id: 'computer', title: 'Computer', icons: ['computer-symbolic']},
    {id: 'desk', title: 'Desk', icons: ['alarm-symbolic', 'appointment-soon-symbolic']},
];
const REFRESH = [[30, '30 seconds'], [60, '1 minute'], [120, '2 minutes'], [300, '5 minutes']];
const EVERY = {30: 'every 30 seconds', 60: 'every minute', 120: 'every 2 minutes', 300: 'every 5 minutes'};
const FOCUS_MINUTES = [15, 25, 50];

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

/// Port of HotchGlyph, the home tab's mark: the app icon's companion curve in
/// the tab's colour, its signal dot always clay.
const Glyph = GObject.registerClass(
class HotchGlyph extends St.DrawingArea {
    _init() {
        super._init({style_class: 'hotch-tab-glyph', x_align: Clutter.ActorAlign.CENTER,
            y_align: Clutter.ActorAlign.CENTER});
    }

    vfunc_repaint() {
        const cr = this.get_context();
        const [w, h] = this.get_surface_size();
        const scale = St.ThemeContext.get_for_stage(global.stage).scale_factor;
        const fg = this.get_theme_node().get_foreground_color();
        cr.setLineWidth(1.9 * scale);
        cr.setLineCap(Cairo.LineCap.ROUND);
        cr.setSourceRGBA(fg.red / 255, fg.green / 255, fg.blue / 255, fg.alpha / 255);
        cr.moveTo(w * 0.60, h * 0.16);
        cr.curveTo(w * 0.17, h * 0.21, w * 0.17, h * 0.79, w * 0.60, h * 0.84);
        cr.stroke();
        // A dark tab colour means the light theme, which takes the deeper clay.
        const light = fg.red + fg.green + fg.blue < 3 * 128;
        cr.setSourceRGBA(...(light ? [0.86, 0.42, 0.28] : [1, 0.55, 0.40]), 1);
        cr.arc(w * 0.66, h * 0.5, w * 0.12, 0, 2 * Math.PI);
        cr.fill();
        cr.$dispose();
    }
});

/// A thin bar for home's computer tiles: faint track, the share in colour.
const Meter = GObject.registerClass(
class HotchMeter extends St.DrawingArea {
    _init(share, color) {
        super._init({style_class: 'hotch-meter', x_expand: true});
        this._share = Math.max(0, Math.min(1, share ?? 0));
        this._color = color;
    }

    vfunc_repaint() {
        const cr = this.get_context();
        const [w, h] = this.get_surface_size();
        const r = h / 2;
        const bar = width => {
            cr.newPath();
            cr.arc(r, r, r, Math.PI / 2, 3 * Math.PI / 2);
            cr.arc(width - r, r, r, -Math.PI / 2, Math.PI / 2);
            cr.closePath();
            cr.fill();
        };
        const fg = this.get_theme_node().get_foreground_color();
        cr.setSourceRGBA(fg.red / 255, fg.green / 255, fg.blue / 255, 0.16);
        bar(w);
        if (this._share > 0) {
            cr.setSourceRGBA(...this._color, 1);
            bar(Math.max(h, w * this._share));
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

/// A row whose children share its width equally, St having no grid.
function columns(styleClass) {
    const row = hbox(styleClass);
    row.layout_manager.homogeneous = true;
    return row;
}

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
        this._tab = 'home';
        this._cancellable = new Gio.Cancellable();

        const box = hbox('hotch-panel-box');
        this._panelRing = new Ring('hotch-panel-ring', 2.2);
        this._panelLabel = label('', 'hotch-panel-label');
        this._panelAlert = label('', 'hotch-panel-alert', {visible: false});
        box.add_child(this._panelRing);
        box.add_child(this._panelLabel);
        box.add_child(this._panelAlert);
        this.add_child(box);

        // The page's name and one line about it on the left, the tabs as icons
        // on the right: one row where a labelled tab bar and a title took two.
        this._card = vbox('hotch-card');
        const header = hbox('hotch-header');
        const heading = vbox('hotch-heading', {x_expand: true, y_align: Clutter.ActorAlign.CENTER});
        this._titleLabel = label('', 'hotch-heading-title');
        this._captionLabel = label('', 'hotch-heading-caption');
        heading.add_child(this._titleLabel);
        heading.add_child(this._captionLabel);
        this._tabs = hbox('hotch-tabs', {y_align: Clutter.ActorAlign.CENTER});
        this._tabButtons = {};
        for (const tab of TABS) {
            const button = new St.Button({style_class: 'hotch-tab', can_focus: true, accessible_name: tab.title});
            button.set_child(tab.icons ? themedIcon(tab.icons, 'hotch-tab-icon') : new Glyph());
            button.connect('clicked', () => this._show(tab.id));
            this._tabButtons[tab.id] = button;
            this._tabs.add_child(button);
        }
        header.add_child(heading);
        header.add_child(this._tabs);
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

        this._card.add_child(header);
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

    /// Check now: an answer lands in the cache the next poll reads. A check
    /// that gets none (offline, rate-limited, no package for this machine)
    /// says so in Settings only; the footer stays quiet.
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
        this._updateFailure = null;
        this._render();
        proc.communicate_utf8_async(null, this._cancellable, (p, res) => {
            this._updateProcess = null;
            let answer = null;
            try {
                answer = JSON.parse(p.communicate_utf8_finish(res)[1]);
            } catch (e) {
                if (e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                    return;
            }
            if (this._cancellable.is_cancelled())
                return;
            if (answer?.answered !== true)
                this._updateFailure = {at: now(), unsupported: answer?.supported === false};
            if (this._tab === 'settings')
                this._render();
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
        if (this._tab === 'desk') {
            this._renderPanel();
            this._renderUpdate();
            this._renderHeader();
            this._ext.pill?.render(this._data);
            this._checkedLabel.text = 'Last check just now';
        } else {
            this._render();
        }
    }

    // MARK: Rendering

    _show(tab) {
        if (tab !== this._tab)
            this._focusDraft = null;
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
        // Settings, opened from the footer, leaves every tab unselected.
        for (const [id, button] of Object.entries(this._tabButtons)) {
            if (id === this._tab)
                button.add_style_pseudo_class('checked');
            else
                button.remove_style_pseudo_class('checked');
        }
        // A task name typed on Desk outlives a redraw (a clipboard switch, a
        // settings reload) until another tab opens.
        if (this._tab === 'desk' && this._focusTitle)
            this._focusDraft = this._focusTitle.get_text();
        this._page.destroy_all_children();
        this._focusClock = this._homeClock = this._focusTitle = this._clipboardBox = null;
        this._renderHeader();
        this._checkedLabel.text = this._checkedAt ? `Last check ${ago(now() - this._checkedAt)}` : 'Checking…';

        // Desk and Settings are usable without the Rust binary; home keeps its
        // Desk block when the binary is missing.
        ({home: this._renderHome, ai: this._renderAI, computer: this._renderComputer,
            desk: this._renderDesk, settings: this._renderSettings})[this._tab].call(this);
    }

    /// What stands in for the binary's readings until it has answered.
    _dataStatus() {
        if (!this._data)
            return label('Reading usage…', 'hotch-muted hotch-empty');
        if (!this._data.missing)
            return null;
        const tile = vbox('hotch-tile');
        tile.add_child(label('hotch is not installed', 'hotch-title'));
        tile.add_child(label('Build it from the linux folder and put it in ~/.local/bin.',
            'hotch-sub', {style: 'max-width: 300px;'}));
        return tile;
    }

    _renderHeader() {
        const [caption, alert] = this._headerCaption();
        this._titleLabel.text = TABS.find(tab => tab.id === this._tab)?.title ?? 'Settings';
        this._captionLabel.text = caption;
        if (alert)
            this._captionLabel.add_style_class_name('hotch-heading-alert');
        else
            this._captionLabel.remove_style_class_name('hotch-heading-alert');
    }

    /// One line about the open page, and whether it is a warning.
    _headerCaption() {
        const s = this._ext.settings;
        switch (this._tab) {
        case 'home':
            return [GLib.DateTime.new_from_unix_local(Math.floor(now())).format('%A %-d %B'), false];
        case 'ai': {
            const sessions = this._data?.sessions ?? [];
            return [sessionSummary(sessions) ?? 'No sessions right now',
                sessions.some(item => item.activity === 'needs input')];
        }
        case 'computer': {
            const sys = this._data?.system;
            if (!sys)
                return ['Waiting for readings', false];
            if (sys.error)
                return ['No readings on this system', false];
            const warning = systemWarning(sys);
            return warning ? [warning, true] : [`Updated ${EVERY[s.refreshSeconds]}`, false];
        }
        case 'desk': {
            const run = focusRun(s.focus, now());
            if (run)
                return [`Focus · ${run.clock} ${run.caption}`, false];
            return [s.clipboardEnabled ? 'Focus and clipboard' : 'Focus · clipboard history off', false];
        }
        default:
            return ['Shared with the tray and CLI', false];
        }
    }

    /// The Focus clock's one-second tick: only clock text changes, so nothing
    /// being typed on Desk is redrawn.
    tick() {
        const f = this._ext.settings.focus;
        if (this._focusClock)
            this._focusClock.text = clockText(focusReading(f, now()).seconds);
        const run = focusRun(f, now());
        if (this._homeClock && run)
            this._homeClock.text = run.clock;
        if (this._tab === 'desk')
            this._renderHeader();
    }

    /// A copy or a cleared history redraws only the clipboard rows on Desk,
    /// so its Focus fields keep what is being typed.
    clipboardChanged() {
        if (this._tab === 'desk' && this._clipboardBox)
            this._renderDeskClipboard();
        else if (this._tab === 'home')
            this._render();
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

    // MARK: Hotch (home)

    /// Home: usage, the computer's vitals and the desk tools at a glance, each
    /// block leading to its tab. Only a session waiting on you pushes in
    /// above them: a blocked agent is the most actionable thing Hotch knows.
    _renderHome() {
        const status = this._dataStatus();
        if (status) {
            this._page.add_child(status);
        } else {
            const sessions = this._data.sessions ?? [];
            for (const s of sessions.filter(item => item.activity === 'needs input').slice(0, 2))
                this._page.add_child(this._needsYou(s));
            const live = sessions.filter(s => ['needs input', 'working', 'shell'].includes(s.activity)).length;
            this._page.add_child(this._blockHeading('AI usage',
                live ? `${live} session${live === 1 ? '' : 's'}` : 'Sessions', 'ai'));
            this._page.add_child(this._homeUsage());
            this._page.add_child(this._blockHeading('This computer', 'More', 'computer'));
            this._page.add_child(this._homeComputer());
        }
        this._page.add_child(this._blockHeading('Desk', 'More', 'desk'));
        this._page.add_child(this._homeDesk());
    }

    /// A home block's small heading, with the way into its tab on the right.
    _blockHeading(title, link, tab) {
        const row = hbox('hotch-block-heading');
        row.add_child(label(title.toUpperCase(), 'hotch-section'));
        row.add_child(spacer());
        const inner = hbox('hotch-block-link-box');
        inner.add_child(label(link, 'hotch-block-link-label'));
        inner.add_child(themedIcon(['go-next-symbolic', 'pan-end-symbolic'], 'hotch-block-chevron'));
        const button = new St.Button({style_class: 'hotch-block-link', can_focus: true,
            accessible_name: `${title}: ${link}`, y_align: Clutter.ActorAlign.END, child: inner});
        button.connect('clicked', () => this._show(tab));
        row.add_child(button);
        return row;
    }

    /// The one line home gives a session that is waiting on you.
    _needsYou(s) {
        const tile = hbox('hotch-tile hotch-attention');
        tile.add_child(themedIcon(['hand-open-symbolic', 'dialog-warning-symbolic'], 'hotch-attention-icon'));
        const text = vbox('hotch-text', {x_expand: true});
        const top = hbox('hotch-attention-line');
        top.add_child(label('Needs you', 'hotch-attention-kicker'));
        top.add_child(label(`· ${s.name}`, 'hotch-attention-name'));
        text.add_child(top);
        const ask = s.waitingFor || s.project;
        if (ask)
            text.add_child(label(ask, 'hotch-sub'));
        tile.add_child(text);
        tile.add_child(themedIcon(['go-next-symbolic', 'pan-end-symbolic'], 'hotch-chevron'));
        return this._link(tile, 'ai');
    }

    /// Up to four providers, two to a row.
    _homeUsage() {
        const usages = this._usages().slice(0, 4);
        if (!usages.length) {
            const row = hbox('hotch-tile');
            row.add_child(label('No AI accounts connected yet', 'hotch-title'));
            row.add_child(spacer());
            row.add_child(label('Settings', 'hotch-muted'));
            return this._link(row, 'settings');
        }
        const grid = vbox('hotch-grid');
        for (let i = 0; i < usages.length; i += 2) {
            const row = columns('hotch-grid-row');
            const pair = usages.slice(i, i + 2);
            for (const u of pair)
                row.add_child(this._link(this._usageTile(u), u.windows.length || !u.error ? 'ai' : 'settings'));
            if (pair.length === 1)
                row.add_child(spacer());
            grid.add_child(row);
        }
        return grid;
    }

    /// A provider at home: its tightest window as a ring around its mark.
    _usageTile(u) {
        const w = headline(u);
        const tile = hbox('hotch-tile hotch-usage-tile');
        tile.add_child(this._markedRing(u.provider, w?.percent ?? null, true));
        const text = vbox('hotch-text', {x_expand: true, y_align: Clutter.ActorAlign.CENTER});
        text.add_child(label(BRANDS[u.provider]?.name ?? u.provider, 'hotch-tile-label'));
        const warn = w ? w.percent >= CRITICAL_PERCENT : Boolean(u.error);
        text.add_child(label(w ? `${this._percent(w.percent)}% ${this._ext.settings.displayMode}` : 'No reading',
            `hotch-tile-value${warn ? ' hotch-amber' : ''}`));
        const note = w ? [w.label, w.resetsAt ? relative(w.resetsAt - now()) : null].filter(Boolean).join(' · ')
            : u.error ?? '';
        if (note)
            text.add_child(label(note, 'hotch-tile-note'));
        tile.add_child(text);
        return tile;
    }

    /// CPU, memory and battery: the readings worth a glance. Linux reads no
    /// temperatures, so the battery stands where the Mac shows thermals.
    _homeComputer() {
        const sys = this._data.system ?? {};
        if (sys.error) {
            const tile = hbox('hotch-tile');
            tile.add_child(label(sys.error, 'hotch-sub'));
            return this._link(tile, 'computer');
        }
        const alerts = systemAlerts(sys);
        const row = columns('hotch-grid-row');
        row.add_child(this._statTile('CPU', sys.cpuPercent ?? null, CPU, alerts.cpu));
        row.add_child(this._statTile('Memory', sys.memTotalGB ? 100 * sys.memUsedGB / sys.memTotalGB : null,
            MEMORY, alerts.memory));
        if (sys.battery)
            row.add_child(this._statTile('Battery', sys.battery.percent, POWER, alerts.battery));
        return row;
    }

    _statTile(name, percent, color, alert) {
        const tile = vbox('hotch-tile hotch-stat-tile');
        tile.add_child(label(name, 'hotch-tile-label'));
        tile.add_child(label(percent === null ? '—' : `${Math.round(percent)}%`,
            `hotch-stat-value${alert ? ' hotch-amber' : ''}`));
        tile.add_child(new Meter(percent === null ? 0 : percent / 100, alert ? WARNING : color));
        return this._link(tile, 'computer');
    }

    /// Focus started in one click, and the last two things copied.
    _homeDesk() {
        const tile = vbox('hotch-tile hotch-desk-tile');
        tile.add_child(this._homeFocus());
        const items = this._ext.settings.clipboardEnabled ? this._ext.clipboardItems.slice(0, 2) : [];
        if (items.length) {
            tile.add_child(new St.Widget({style_class: 'hotch-divider hotch-desk-divider'}));
            for (const text of items)
                tile.add_child(this._clipboardRow(text));
        }
        return tile;
    }

    _homeFocus() {
        const f = this._ext.settings.focus;
        const run = focusRun(f, now());
        const row = hbox('hotch-row hotch-focus-row');
        if (run) {
            row.add_child(themedIcon([run.paused ? 'media-playback-pause-symbolic' : 'alarm-symbolic'], 'hotch-row-icon'));
            row.add_child(label(f.title || 'Focus', 'hotch-row-label', {x_expand: true}));
            this._homeClock = label(run.clock, 'hotch-focus-value');
            row.add_child(this._homeClock);
            row.add_child(label(run.caption, 'hotch-muted'));
            return this._link(row, 'desk');
        }
        row.add_child(themedIcon(['alarm-symbolic'], 'hotch-row-icon'));
        row.add_child(label('Focus', 'hotch-row-label'));
        row.add_child(spacer());
        for (const minutes of FOCUS_MINUTES)
            row.add_child(this._chip(`${minutes}m`, `Start a ${minutes} minute timer`, () => this._quickFocus(minutes)));
        row.add_child(this._chip('Stopwatch', 'Start a stopwatch', () => this._quickFocus(null)));
        return row;
    }

    _quickFocus(minutes) {
        this._ext.updateSettings({focus: quickFocus(this._ext.settings.focus, minutes, now())});
    }

    _chip(text, name, callback) {
        const button = new St.Button({style_class: 'hotch-chip', can_focus: true, label: text, accessible_name: name});
        button.connect('clicked', callback);
        return button;
    }

    /// Copied text as a short row: select it to copy it again.
    _clipboardRow(text) {
        const preview = text.replace(/\s+/g, ' ').trim().slice(0, 100);
        const row = hbox('hotch-row hotch-clip-row');
        row.add_child(themedIcon(['edit-paste-symbolic'], 'hotch-row-icon'));
        row.add_child(label(preview, 'hotch-row-label', {x_expand: true}));
        const button = new St.Button({style_class: 'hotch-link', x_expand: true, x_align: Clutter.ActorAlign.FILL,
            can_focus: true, accessible_name: `Copy ${preview}`, child: row});
        button.connect('clicked', () => this._ext.copyClipboard(text));
        return button;
    }

    /// A provider's ring with its brand mark inside the gauge.
    _markedRing(provider, percent, small = false) {
        const brand = BRANDS[provider] ?? {accent: [0.78, 0.78, 0.8]};
        const stack = new St.Widget({layout_manager: new Clutter.BinLayout(), y_align: Clutter.ActorAlign.CENTER});
        const ring = new Ring(small ? 'hotch-ring-small' : 'hotch-ring', small ? 3 : 3.5);
        ring.setValue(percent, brand.accent, brand.highlight, true, this._remaining());
        stack.add_child(ring);
        const mark = markIcon(this._ext.dir, provider, small ? 'hotch-ring-mark-small' : 'hotch-ring-mark');
        if (mark) {
            mark.x_align = Clutter.ActorAlign.CENTER;
            stack.add_child(mark);
        }
        return stack;
    }

    // MARK: AI

    /// Every provider with its usage windows, and the sessions running on it
    /// nested beneath: usage and the work spending it, in one place.
    _renderAI() {
        const status = this._dataStatus();
        if (status) {
            this._page.add_child(status);
            return;
        }
        const usages = this._usages();
        const sessions = this._data.sessions ?? [];
        // Providers in usage order, then any with sessions but no reading.
        const ids = usages.map(u => u.provider);
        for (const s of sessions) {
            if (!ids.includes(s.provider))
                ids.push(s.provider);
        }
        if (!ids.length) {
            this._page.add_child(label('No AI providers found. Install and sign in to Claude Code or Codex.',
                'hotch-muted hotch-empty'));
            this._page.add_child(this._action('Open Settings', () => this._show('settings')));
            return;
        }
        for (const id of ids)
            this._page.add_child(this._providerGroup(id, usages.find(u => u.provider === id),
                sessions.filter(s => s.provider === id)));
    }

    _providerGroup(id, u, sessions) {
        const brand = BRANDS[id] ?? {name: id, accent: [0.78, 0.78, 0.8]};
        const tile = vbox('hotch-tile hotch-tile-list');
        const head = hbox('hotch-provider-head');
        const mark = markIcon(this._ext.dir, id, 'hotch-head-mark');
        if (mark)
            head.add_child(mark);
        head.add_child(label(brand.name, 'hotch-title'));
        if (u?.plan)
            head.add_child(label(`${u.plan} plan`, 'hotch-muted'));
        tile.add_child(head);
        if (u && !u.windows.length)
            tile.add_child(label(u.error ?? 'No reading', 'hotch-sub'));
        for (const w of u?.windows ?? []) {
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
        for (const extra of u?.extras ?? [])
            tile.add_child(label(extra, 'hotch-muted'));
        if (u?.stale)
            tile.add_child(label(readingStatus(u, now()), 'hotch-sub'));
        if (sessions.length) {
            const list = vbox('hotch-session-list');
            for (const s of sessions)
                list.add_child(this._sessionRow(s));
            tile.add_child(list);
        }
        return tile;
    }

    /// A session under its provider: what it is waiting on, or where it runs
    /// and when it last moved.
    _sessionRow(s) {
        const row = hbox('hotch-session-row');
        const text = vbox('hotch-text', {x_expand: true});
        text.add_child(label(s.name, 'hotch-session-name'));
        const ask = s.activity === 'needs input' ? s.waitingFor : null;
        const where = s.project ? `${s.project} · ` : '';
        text.add_child(label(ask ?? `${where}${ago(now() - s.lastEventAt)}`, ask ? 'hotch-sub hotch-amber' : 'hotch-sub'));
        row.add_child(text);
        row.add_child(label(statusWord({...s, waitingFor: null}), `hotch-state hotch-state-${s.activity.replace(' ', '-')}`));
        return row;
    }

    // MARK: Computer

    _renderComputer() {
        const status = this._dataStatus();
        if (status) {
            this._page.add_child(status);
            return;
        }
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
        this._choice('HOME', HOMES, s.home, home => this._ext.setHome(home));
        this._choice('APPEARANCE', [['system', 'System'], ['dark', 'Dark'], ['light', 'Light']], s.theme,
            theme => this._ext.updateSettings({theme}));
        this._choice('USAGE DISPLAY', [['used', 'Used'], ['remaining', 'Remaining']], s.displayMode,
            displayMode => this._ext.updateSettings({displayMode}));
        this._choice('REFRESH', REFRESH, s.refreshSeconds,
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
        // A Check now that got no answer shows until a later check answers.
        const failure = this._updateFailure;
        let status = 'Not checked yet';
        if (this._updateProcess)
            status = 'Checking GitHub…';
        else if (failure?.unsupported)
            status = 'Update checks cover the amd64 and arm64 Linux packages only';
        else if (failure && !(u?.checkedAt >= failure.at))
            status = 'Could not check right now; try again later';
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

    // MARK: Desk

    /// Desk: the tools you switch on. Focus, then clipboard history.
    _renderDesk() {
        const f = this._ext.settings.focus;
        const reading = focusReading(f, now());
        this._page.add_child(label('FOCUS', 'hotch-section'));
        this._focusClock = label(clockText(reading.seconds), 'hotch-focus-clock');
        this._page.add_child(this._focusClock);
        this._page.add_child(label(reading.done ? 'Timer complete' : f.startedAt !== null ? 'Running' : f.elapsed ? 'Paused' : 'Ready', 'hotch-sub'));
        const title = new St.Entry({style_class: 'hotch-entry', hint_text: 'What are you working on?', can_focus: true,
            text: this._focusDraft ?? f.title});
        this._focusTitle = title;
        this._page.add_child(title);
        let minutes;
        if (f.elapsed === 0 && f.startedAt === null) {
            this._choice('MODE', [['timer', 'Timer'], ['stopwatch', 'Stopwatch']], f.mode,
                mode => this._ext.updateSettings({focus: {...f, mode, title: title.get_text()}}));
            if (f.mode === 'timer') {
                this._choice('DURATION', FOCUS_MINUTES.map(m => [m * 60, `${m} min`]), f.duration,
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

        this._page.add_child(label('CLIPBOARD', 'hotch-section'));
        this._clipboardBox = vbox('hotch-page');
        this._page.add_child(this._clipboardBox);
        this._renderDeskClipboard();
    }

    _renderDeskClipboard() {
        const box = this._clipboardBox;
        box.destroy_all_children();
        if (!this._ext.settings.clipboardEnabled) {
            box.add_child(this._paragraph('Clipboard history is off. Enable it to remember future text copies in memory. Applications must supply privacy markers for Hotch to recognise sensitive copies.'));
            box.add_child(this._action('Enable clipboard history', () => this._ext.updateSettings({clipboardEnabled: true})));
            return;
        }
        if (this._ext.clipboardItems.length) {
            const list = vbox('hotch-tile hotch-clip-list');
            for (const text of this._ext.clipboardItems)
                list.add_child(this._clipboardRow(text));
            box.add_child(list);
        } else {
            box.add_child(this._paragraph('Future text copies will appear here. Select an entry to copy it again.'));
        }
        const actions = hbox('hotch-choices');
        actions.add_child(this._action('Clear history', () => this._ext.clearClipboard()));
        actions.add_child(this._action('Disable and clear', () => this._ext.updateSettings({clipboardEnabled: false})));
        box.add_child(actions);
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
                this._indicator.tick();
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
                    this._indicator.clipboardChanged();
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
        this._indicator.clipboardChanged();
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
