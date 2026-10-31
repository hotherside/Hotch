// Exercise the actual extension lifecycle against a small GNOME API double.
// This catches disposed-card, timer and clipboard races; it is not visual QA.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import * as model from '../gnome-extension/model.js';
import * as data from '../gnome-extension/data.js';

function shell() {
    class Signals {
        constructor() { this.signals = new Map(); this.nextSignal = 0; }
        connect(name, callback) { const id = ++this.nextSignal; this.signals.set(id, {name, callback}); return id; }
        disconnect(id) { this.signals.delete(id); }
        emit(name, ...args) { for (const s of [...this.signals.values()]) if (s.name === name) s.callback(this, ...args); }
    }
    class Actor extends Signals {
        constructor(...args) { super(); this._init(...args); }
        _init(props = {}) {
            this.children = []; this.classes = new Set(); this.x = 0; this.y = 0; this.layout_manager = {};
            this.clutter_text = new Signals(); Object.assign(this, props);
            if (props.child) this.set_child(props.child);
        }
        add_child(child) { assert.equal(this.dead, undefined, 'actor already destroyed'); child.parent?.remove_child(child); this.children.push(child); child.parent = this; }
        remove_child(child) { this.children = this.children.filter(c => c !== child); child.parent = null; }
        get_parent() { return this.parent; }
        remove_all_children() { for (const child of [...this.children]) this.remove_child(child); }
        destroy_all_children() { for (const child of [...this.children]) child.destroy(); }
        destroy() { this.destroy_all_children(); this.parent?.remove_child(this); this.dead = true; }
        set_child(child) { this.remove_all_children(); this.add_child(child); }
        add_style_class_name(name) { this.classes.add(name); }
        remove_style_class_name(name) { this.classes.delete(name); }
        add_style_pseudo_class(name) { this.pseudo = name; }
        remove_style_pseudo_class() { this.pseudo = null; }
        queue_repaint() {}
        hide() { this.visible = false; }
        get_preferred_width() { return [120, 120]; }
        get_preferred_height() { return [80, 80]; }
        set_position(x, y) { this.x = x; this.y = y; }
        set_style(style) { this.style = style; }
        get_text() { return this.text ?? ''; }
    }
    class Menu extends Signals {
        constructor() { super(); this.actor = new Actor(); this.box = new Actor(); this.actor.add_child(this.box); }
        open() { this.opened = true; this.emit('open-state-changed', true); }
        close() { this.opened = false; this.emit('open-state-changed', false); }
        toggle() { if (this.opened) this.close(); else this.open(); }
        destroy() { this.actor.destroy(); }
    }
    class Panel extends Actor {
        _init() { super._init(); this.menu = new Menu(); this.container = this; }
        destroy() { this.menu.destroy(); super.destroy(); }
    }
    const timers = new Map(); let timerId = 0; let time = 1000;
    const selection = new Signals(); const clipboardCallbacks = [];
    const clipboard = {types: ['text/plain'], text: '', reads: 0,
        get_mimetypes() { return this.types; },
        get_text(_type, callback) { this.reads++; const text = this.text; clipboardCallbacks.push(() => callback(this, text)); },
        set_text(_type, text) { this.text = text; },
    };
    const fixture = {usage: [{provider: 'claude', windows: [{label: 'Session', percent: 42}], extras: [], fetchedAt: 1000}],
        sessions: [{provider: 'claude', activity: 'needs input', name: 'Fixture', lastEventAt: 1000}],
        system: {cpuPercent: 25, memUsedGB: 8, memTotalGB: 16}};
    const file = {replace_contents() {}, set_attribute_uint32() {}, get_child() { return this; },
        monitor_directory() { return Object.assign(new Signals(), {cancel() {}}); }};
    const layout = Object.assign(new Signals(), {primaryMonitor: {x: 0, y: 0, width: 1280, height: 720},
        addChrome(actor) { actor.chrome = true; }, removeChrome(actor) { actor.chrome = false; }});
    layout.monitors = [layout.primaryMonitor];
    const notifications = [], launched = [], processes = [];
    const context = {
        ...model, ...data, TextDecoder, TextEncoder,
        Date: {now: () => time * 1000},
        GObject: {registerClass: cls => cls},
        St: {Widget: Actor, BoxLayout: Actor, Button: Actor, Label: Actor, Icon: Actor, Entry: Actor,
            DrawingArea: Actor, ScrollView: Actor, Clipboard: {get_default: () => clipboard},
            ClipboardType: {CLIPBOARD: 1}, PolicyType: {NEVER: 0, AUTOMATIC: 1}, Side: {TOP: 0}},
        Clutter: {ActorAlign: {}, Orientation: {VERTICAL: 1, HORIZONTAL: 0}, BinLayout: class {}},
        Cairo: {}, Shell: {}, Meta: {SelectionType: {SELECTION_CLIPBOARD: 1}},
        GLib: {PRIORITY_DEFAULT: 0, SOURCE_CONTINUE: true, SOURCE_REMOVE: false,
            get_user_config_dir: () => '/fixture', get_home_dir: () => '/fixture',
            build_filenamev: a => a.join('/'), file_get_contents() { throw Error('no config'); },
            path_get_dirname: () => '/fixture/hotch', mkdir_with_parents() {}, getenv: () => null,
            find_program_in_path: () => '/fixture/hotch-bin', file_test: () => true, FileTest: {IS_EXECUTABLE: 1},
            timeout_add_seconds(_p, _s, f) { timers.set(++timerId, f); return timerId; },
            timeout_add(_p, _s, f) { timers.set(++timerId, f); return timerId; },
            source_remove(id) { timers.delete(id); },
            DateTime: {new_from_unix_local: () => ({format: () => 'Saturday 31 October'})}},
        Gio: {Settings: class extends Signals { get_string() { return 'prefer-dark'; } },
            Cancellable: class { cancel() { this.cancelled = true; } is_cancelled() { return !!this.cancelled; } },
            File: {new_for_path: () => file}, FileMonitorFlags: {}, FileCreateFlags: {}, FileQueryInfoFlags: {},
            ThemedIcon: {new_from_names: () => ({})}, FileIcon: {new: () => ({})},
            AppInfo: {launch_default_for_uri: uri => launched.push(uri)},
            SubprocessFlags: {}, Subprocess: {new: argv => {
                const proc = {argv, force_exit() { this.exited = true; },
                    communicate_utf8_async(_a, _b, callback) { this.callback = callback; },
                    communicate_utf8_finish() { return [true, this.output ?? JSON.stringify(fixture)]; }};
                processes.push(proc);
                return proc;
            }}},
        Main: {layoutManager: layout, panel: {height: 30, addToStatusArea() {}}, uiGroup: new Actor(),
            notify: (...args) => notifications.push(args)},
        PanelMenu: {Button: Panel}, PopupMenu: {PopupMenu: Menu, PopupMenuManager: class { addMenu() {} }},
        Extension: class { constructor() { this.metadata = {'version-name': 'test'}; this.dir = file; } },
        global: {display: {get_selection: () => selection}, create_app_launch_context: () => null},
        logError(e) { throw e; },
    };
    const source = readFileSync(new URL('../gnome-extension/extension.js', import.meta.url), 'utf8')
        .replace(/^import[\s\S]*?;\n/gm, '').replace('export default class HotchExtension', 'class HotchExtension');
    vm.runInNewContext(`${source}\nthis.HotchExtension = HotchExtension;`, context);
    const extension = new context.HotchExtension();
    return {extension, timers, selection, clipboard, clipboardCallbacks, notifications, launched, processes,
        advance: seconds => { time += seconds; }};
}

test('all pages and placements preserve the shared card and clean up resources', () => {
    const {extension: e, timers} = shell();
    e.enable();
    const card = e._indicator._card;
    for (const [home] of model.HOMES) {
        e.setHome(home);
        const menu = e.pill?.menu ?? e._indicator.menu;
        menu.open();
        assert.equal(card.dead, undefined, `${home} disposed the shared card`);
        for (const tab of ['home', 'ai', 'computer', 'desk', 'settings']) {
            e._indicator._show(tab);
            assert.ok(e._indicator._page.children.length);
        }
        e.updateSettings({theme: 'light'});
        assert.equal(menu.actor.classes.has('hotch-light'), true);
    }
    e.disable();
    assert.equal(timers.size, 0);
    assert.equal(card.dead, true);
});

test('clipboard opt-in skips sensitive types and rejects pending reads after disabling', () => {
    const {extension: e, selection, clipboard: c, clipboardCallbacks: pending} = shell();
    e.enable();
    selection.emit('owner-changed', 1);
    assert.equal(c.reads, 0);
    e.updateSettings({clipboardEnabled: true});
    c.types = ['text/plain', 'x-kde-passwordManagerHint'];
    selection.emit('owner-changed', 1);
    assert.equal(c.reads, 0);
    c.types = ['text/plain']; c.text = 'fixture';
    selection.emit('owner-changed', 1); pending.shift()();
    assert.equal(e.clipboardItems[0], 'fixture');
    c.text = 'pending'; selection.emit('owner-changed', 1);
    e.updateSettings({clipboardEnabled: false}); pending.shift()();
    assert.equal(e.clipboardItems.length, 0);
    e.disable();
    assert.equal(selection.signals.size, 0);
});

test('Focus completion notifies once and stops its one-second source', () => {
    const {extension: e, timers, advance, notifications} = shell();
    e.enable();
    e.updateSettings({focus: {...e.settings.focus, duration: 60, startedAt: 1000}});
    const id = e._focusTimer;
    advance(61);
    assert.equal(timers.get(id)(), false);
    timers.delete(id); // GLib removes a source returning SOURCE_REMOVE.
    assert.equal(e.settings.focus.startedAt, null);
    assert.equal(e.settings.focus.elapsed, 60);
    assert.equal(notifications.length, 1);
    assert.equal(e._focusTimer, null);
    e.disable();
    assert.equal(timers.size, 0);
});

test('background provider refresh preserves Focus input widgets', () => {
    const {extension: e} = shell();
    e.enable();
    e._indicator._show('desk');
    const widgets = [...e._indicator._page.children];
    e._indicator._apply({usage: [], sessions: [], system: {}});
    assert.deepEqual(e._indicator._page.children, widgets);
    assert.ok(widgets.every(widget => !widget.dead));
    e.disable();
});

const texts = actor => [actor.text, actor.label, ...actor.children.flatMap(texts)].filter(t => typeof t === 'string');

test('update notice opens the release page, skips a version and stays off when disabled', () => {
    const {extension: e, launched, processes, advance} = shell();
    e.enable();
    const indicator = e._indicator;
    const release = {current: '2.3.0', latest: '2.4.0', checkedAt: 1000, available: true,
        url: 'https://github.com/hotherside/Hotch/releases/tag/v2.4.0'};
    const poll = update => indicator._apply({usage: [], sessions: [], system: {}, update});
    const [startup] = processes;
    startup.callback(startup, null);
    assert.equal(indicator._updateRow.visible, false);
    poll(release);
    assert.equal(indicator._updateRow.visible, true);
    assert.equal(indicator._updateLabel.text, 'Hotch 2.4.0 is available');

    indicator.menu.open();
    indicator._updateRow.children[0].emit('clicked');
    assert.deepEqual(launched, [release.url]);
    assert.equal(indicator.menu.opened, false);

    indicator._updateSkip.emit('clicked');
    assert.equal(e.settings.updateSkipped, '2.4.0');
    assert.equal(indicator._updateRow.visible, false);
    poll({...release, latest: '2.5.0', url: 'https://github.com/hotherside/Hotch/releases/tag/v2.5.0'});
    assert.equal(indicator._updateLabel.text, 'Hotch 2.5.0 is available');

    // Off: no footer line, but Settings still shows what a check found.
    e.updateSettings({updateChecks: false});
    assert.equal(indicator._updateRow.visible, false);
    indicator._show('settings');
    assert.ok(texts(indicator._page).includes('Hotch 2.5.0 is available'));
    assert.ok(texts(indicator._page).includes('○ Check for updates daily'));

    const checkNow = indicator._page.children.flatMap(c => [c, ...c.children]).find(c => c.label === 'Check now');
    checkNow.emit('clicked');
    const check = processes.at(-1);
    assert.equal(check.argv.join(' '), '/fixture/hotch-bin update-check --json');
    assert.ok(texts(indicator._page).includes('Checking GitHub…'));
    check.output = JSON.stringify({update: release, answered: true, supported: true});
    check.callback(check, null);
    assert.equal(indicator._updateProcess, null);
    assert.ok(texts(indicator._page).includes('Hotch 2.5.0 is available'));
    assert.equal(processes.at(-1).argv.join(' '), '/fixture/hotch-bin all --json');

    // Offline or rate-limited: Settings says so; the footer stays quiet.
    advance(3600);
    const settings = () => indicator._page.children.flatMap(c => [c, ...c.children]);
    const failed = () => {
        settings().find(c => c.label === 'Check now').emit('clicked');
        return processes.at(-1);
    };
    let offline = failed();
    offline.output = JSON.stringify({update: {...release, available: false}, answered: false, supported: true});
    offline.callback(offline, null);
    assert.ok(texts(indicator._page).includes('Could not check right now; try again later'));
    assert.equal(indicator._updateRow.visible, false);
    offline = failed();
    offline.output = 'not json';
    offline.callback(offline, null);
    assert.ok(texts(indicator._page).includes('Could not check right now; try again later'));
    const unsupported = failed();
    unsupported.output = JSON.stringify({update: {}, answered: false, supported: false});
    unsupported.callback(unsupported, null);
    assert.ok(texts(indicator._page).includes('Update checks cover the amd64 and arm64 Linux packages only'));
    e.disable();
});

const all = actor => [actor, ...actor.children.flatMap(all)];
const taskField = page => all(page).find(a => a.hint_text === 'What are you working on?');

test('four tabs reach every old section: home, AI with nested sessions, Computer and Desk', () => {
    const {extension: e} = shell();
    e.enable();
    const indicator = e._indicator;
    e.updateSettings({clipboardEnabled: true});
    e.clipboardItems = ['first copy', 'second copy', 'third copy'];
    const sessions = [
        {provider: 'claude', activity: 'needs input', name: 'Fixture', project: 'hotch', waitingFor: 'Approve Bash', lastEventAt: 1000},
        {provider: 'codex', activity: 'working', name: 'Codex run', project: 'web', lastEventAt: 990},
    ];
    indicator._apply({
        usage: [{provider: 'claude', windows: [{label: 'Session', percent: 42, resetsAt: 1000 + 7200}], extras: [], plan: 'Max', fetchedAt: 1000}],
        sessions, system: {cpuPercent: 25, memUsedGB: 8, memTotalGB: 16, battery: {percent: 15, status: 'Discharging'}},
    });

    // Home: the waiting session first, then usage, the computer and the desk.
    assert.equal(indicator._tab, 'home');
    assert.equal(indicator._titleLabel.text, 'Hotch');
    assert.equal(indicator._captionLabel.text, 'Saturday 31 October');
    assert.equal(texts(indicator._page.children[0])[0], 'Needs you');
    const home = texts(indicator._page);
    for (const text of ['· Fixture', 'Approve Bash', 'AI USAGE', '2 sessions', 'Claude', '42% used', 'Session · 2h 0m',
        'THIS COMPUTER', 'CPU', '25%', 'Memory', '50%', 'Battery', '15%', 'DESK', 'Focus', '15m', '25m', '50m',
        'Stopwatch', 'first copy', 'second copy'])
        assert.ok(home.includes(text), text);
    assert.ok(!home.includes('third copy'), 'home shows only the last two copies');

    // AI: each provider's windows with its own sessions beneath, Codex
    // included without a usage reading.
    indicator._show('ai');
    assert.equal(indicator._captionLabel.text, '1 needs input · 1 working');
    assert.ok(indicator._captionLabel.classes.has('hotch-heading-alert'));
    const [claude, codex] = indicator._page.children;
    for (const text of ['Max plan', 'Session', '42% used', 'Fixture', 'Approve Bash', 'needs you'])
        assert.ok(texts(claude).includes(text), text);
    assert.ok(texts(codex).includes('Codex run'));
    assert.ok(!texts(claude).includes('Codex run'));

    indicator._show('computer');
    assert.equal(indicator._titleLabel.text, 'Computer');
    assert.equal(indicator._captionLabel.text, 'Battery is low');
    assert.ok(texts(indicator._page).includes('8.0 of 16 GB'));

    indicator._show('desk');
    assert.equal(indicator._captionLabel.text, 'Focus and clipboard');
    assert.ok(!indicator._captionLabel.classes.has('hotch-heading-alert'));
    const desk = texts(indicator._page);
    for (const text of ['FOCUS', '25:00', 'CLIPBOARD', 'first copy', 'third copy', 'Clear history'])
        assert.ok(desk.includes(text), text);

    // The footer's gear opens Settings with no tab selected.
    indicator._show('settings');
    assert.equal(indicator._titleLabel.text, 'Settings');
    assert.ok(Object.values(indicator._tabButtons).every(button => !button.pseudo));

    // Nothing waiting: no needs-you line.
    indicator._show('home');
    indicator._apply({usage: [], sessions: [sessions[1]], system: {}});
    assert.ok(!texts(indicator._page).includes('Needs you'));
    assert.ok(texts(indicator._page).includes('1 session'));
    e.disable();
});

test('home starts Focus in one click and its clock ticks without a redraw', () => {
    const {extension: e, timers, advance} = shell();
    e.enable();
    const indicator = e._indicator;
    all(indicator._page).find(a => a.label === '25m').emit('clicked');
    assert.deepEqual([e.settings.focus.mode, e.settings.focus.duration, e.settings.focus.startedAt], ['timer', 1500, 1000]);
    const clock = indicator._homeClock;
    assert.equal(clock.text, '25:00');
    assert.ok(texts(indicator._page).includes('left'));
    assert.ok(!all(indicator._page).some(a => a.label === '25m'), 'chips give way to the running clock');
    advance(60);
    timers.get(e._focusTimer)();
    assert.equal(indicator._homeClock, clock);
    assert.equal(clock.text, '24:00');

    indicator._show('desk');
    assert.equal(indicator._captionLabel.text, 'Focus · 24:00 left');
    advance(1);
    timers.get(e._focusTimer)();
    assert.equal(indicator._captionLabel.text, 'Focus · 23:59 left');

    e.updateSettings({focus: {...e.settings.focus, startedAt: null, elapsed: 0}});
    indicator._show('home');
    all(indicator._page).find(a => a.label === 'Stopwatch').emit('clicked');
    assert.equal(e.settings.focus.mode, 'stopwatch');
    assert.equal(indicator._homeClock.text, '00:00');
    assert.ok(texts(indicator._page).includes('elapsed'));
    e.disable();
    assert.equal(timers.size, 0);
});

test('Desk redraws only its clipboard rows for a copy, and keeps a typed task name', () => {
    const {extension: e, selection, clipboard: c, clipboardCallbacks: pending} = shell();
    e.enable();
    const indicator = e._indicator;
    indicator._show('desk');
    taskField(indicator._page).text = 'Draft plan';

    // Switching clipboard history on redraws Desk; the typed name survives.
    all(indicator._page).find(a => a.label === 'Enable clipboard history').emit('clicked');
    const field = taskField(indicator._page);
    assert.equal(field.get_text(), 'Draft plan');

    // A copy and a cleared history rebuild only the clipboard rows.
    c.text = 'copied text';
    selection.emit('owner-changed', 1);
    pending.shift()();
    assert.ok(all(indicator._page).includes(field));
    assert.ok(texts(indicator._page).includes('copied text'));
    all(indicator._page).find(a => a.label === 'Clear history').emit('clicked');
    assert.ok(all(indicator._page).includes(field));
    assert.equal(field.dead, undefined);
    assert.ok(!texts(indicator._page).includes('copied text'));

    // Opening another tab drops the unsaved name.
    indicator._show('home');
    indicator._show('desk');
    assert.equal(taskField(indicator._page).get_text(), '');
    e.disable();
});
