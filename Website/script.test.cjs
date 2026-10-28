const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { runInNewContext } = require('node:vm');

const html = readFileSync(join(__dirname, 'index.html'), 'utf8');
const script = readFileSync(join(__dirname, 'script.js'), 'utf8');

function fixture() {
  let focused;
  const elements = new Map();
  function element(id) {
    const tag = html.match(new RegExp(`<[^>]+\\bid="${id}"[^>]*>`))[0];
    const attrs = Object.fromEntries([...tag.matchAll(/([\w-]+)="([^"]*)"/g)].map(match => match.slice(1)));
    const node = {
      attrs, handlers: {}, hidden: /\shidden[\s>]/.test(tag), tabIndex: Number(attrs.tabindex),
      getAttribute: name => attrs[name],
      setAttribute: (name, value) => { attrs[name] = value; },
      addEventListener(type, handler) { this.handlers[type] = handler; },
      focus() { focused = this; },
    };
    elements.set(id, node);
    return node;
  }
  const play = element('demo-play');
  const status = element('playback-status');
  let icon;
  play.querySelector = () => ({ setAttribute: (name, value) => { icon = value; } });
  const tabs = ['queue', 'subtitles', 'airplay'].map(name => element(`tab-${name}`));
  const panels = tabs.map(tab => element(tab.attrs['aria-controls']));
  runInNewContext(script, { document: {
    querySelector: selector => elements.get(selector.slice(1)),
    querySelectorAll: () => tabs,
    getElementById: id => elements.get(id),
  } });
  return { play, status, tabs, panels, icon: () => icon, focused: () => focused };
}

function assertSelected(ui, index) {
  ui.tabs.forEach((tab, i) => {
    assert.equal(tab.attrs['aria-selected'], String(i === index));
    assert.equal(tab.tabIndex, i === index ? 0 : -1);
    assert.equal(ui.panels[i].hidden, i !== index);
  });
}

test('demo pause and resume keep label, pressed state, icon and visible status in sync', () => {
  const ui = fixture();
  assert.equal(ui.play.attrs['aria-pressed'], 'true');
  ui.play.handlers.click();
  assert.equal(ui.play.attrs['aria-pressed'], 'false');
  assert.equal(ui.play.attrs['aria-label'], 'Продолжить демонстрацию');
  assert.equal(ui.icon(), '#i-play');
  assert.equal(ui.status.textContent, 'На паузе');
  ui.play.handlers.click();
  assert.equal(ui.play.attrs['aria-pressed'], 'true');
  assert.equal(ui.play.attrs['aria-label'], 'Поставить демонстрацию на паузу');
  assert.equal(ui.icon(), '#i-pause');
  assert.equal(ui.status.textContent, 'Воспроизводится на телевизоре');
});

test('each clicked tab exposes only its panel and remains the sole tab stop', () => {
  const ui = fixture();
  assertSelected(ui, 0);
  for (const index of [1, 2, 0]) {
    ui.tabs[index].handlers.click();
    assertSelected(ui, index);
  }
});

test('vertical arrow keys wrap and Home/End focus and select the boundary tabs', () => {
  const ui = fixture();
  for (const [from, key, to] of [[0, 'ArrowUp', 2], [2, 'ArrowDown', 0], [0, 'ArrowDown', 1], [1, 'ArrowUp', 0], [0, 'End', 2], [2, 'Home', 0]]) {
    let prevented = false;
    ui.tabs[from].handlers.keydown({ key, preventDefault() { prevented = true; } });
    assert.equal(prevented, true);
    assertSelected(ui, to);
    assert.equal(ui.focused(), ui.tabs[to]);
  }
});

test('unhandled keys preserve selection and native key behavior', () => {
  const ui = fixture();
  for (const key of ['Tab', 'ArrowLeft', 'ArrowRight', 'Escape', 'Enter', ' ']) {
    ui.tabs[0].handlers.keydown({ key, preventDefault() { assert.fail(`${key} was intercepted`); } });
    assertSelected(ui, 0);
    assert.equal(ui.focused(), undefined);
  }
});
