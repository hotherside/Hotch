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
            this.children = []; this.classes = new Set(); this.x = 0; this.y = 0;
            this.clutter_text = new Signals(); Object.assign(this, props);
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
        add_style_pseudo_class() {}
        remove_style_pseudo_class() {}
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
    const notifications = [];
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
            source_remove(id) { timers.delete(id); }},
        Gio: {Settings: class extends Signals { get_string() { return 'prefer-dark'; } },
            Cancellable: class { cancel() { this.cancelled = true; } is_cancelled() { return !!this.cancelled; } },
            File: {new_for_path: () => file}, FileMonitorFlags: {}, FileCreateFlags: {}, FileQueryInfoFlags: {},
            ThemedIcon: {new_from_names: () => ({})}, FileIcon: {new: () => ({})},
            SubprocessFlags: {}, Subprocess: {new: () => ({force_exit() {},
                communicate_utf8_async(_a, _b, callback) { this.callback = callback; },
                communicate_utf8_finish() { return [true, JSON.stringify(fixture)]; }})}},
        Main: {layoutManager: layout, panel: {height: 30, addToStatusArea() {}}, uiGroup: new Actor(),
            notify: (...args) => notifications.push(args)},
        PanelMenu: {Button: Panel}, PopupMenu: {PopupMenu: Menu, PopupMenuManager: class { addMenu() {} }},
        Extension: class { constructor() { this.metadata = {'version-name': 'test'}; this.dir = file; } },
        global: {display: {get_selection: () => selection}},
        logError(e) { throw e; },
    };
    const source = readFileSync(new URL('../gnome-extension/extension.js', import.meta.url), 'utf8')
        .replace(/^import[\s\S]*?;\n/gm, '').replace('export default class HotchExtension', 'class HotchExtension');
    vm.runInNewContext(`${source}\nthis.HotchExtension = HotchExtension;`, context);
    const extension = new context.HotchExtension();
    return {extension, timers, selection, clipboard, clipboardCallbacks, notifications,
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
        for (const tab of ['now', 'ai', 'sessions', 'system', 'focus', 'clipboard', 'settings']) {
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
    e._indicator._show('focus');
    const widgets = [...e._indicator._page.children];
    e._indicator._apply({usage: [], sessions: [], system: {}});
    assert.deepEqual(e._indicator._page.children, widgets);
    assert.ok(widgets.every(widget => !widget.dead));
    e.disable();
});
