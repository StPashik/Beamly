const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { runInNewContext } = require('node:vm');

const pages = {
  ru: readFileSync(join(__dirname, 'index.html'), 'utf8'),
  en: readFileSync(join(__dirname, 'en.html'), 'utf8'),
};
const script = readFileSync(join(__dirname, 'script.js'), 'utf8');
const playback = {
  ru: ['Поставить демонстрацию на паузу', 'Продолжить демонстрацию', 'Воспроизводится на телевизоре', 'На паузе'],
  en: ['Pause the demo', 'Resume the demo', 'Playing on your TV', 'Paused'],
};
const attributes = tag => Object.fromEntries([...tag.matchAll(/([\w-]+)="([^"]*)"/g)].map(match => match.slice(1)));
const languageTags = html => html.match(/<a\b[^>]*\bclass="language-link"[^>]*>/g) || [];

function fixture(language = 'ru', options = {}) {
  const html = pages[language];
  let focused, icon, revealEntries;
  const observed = new Set();
  const redirects = [];
  const stored = new Map(options.saved ? [['beamly-language', options.saved]] : []);
  const elements = new Map();
  function node(tag) {
    const attrs = attributes(tag);
    const classes = new Set((attrs.class || '').split(/\s+/));
    return {
      attrs, handlers: {}, hidden: /\shidden[\s>]/.test(tag), tabIndex: Number(attrs.tabindex),
      classList: { add: value => classes.add(value), contains: value => classes.has(value) },
      getAttribute: name => attrs[name],
      setAttribute: (name, value) => { attrs[name] = value; },
      addEventListener(type, handler) { this.handlers[type] = handler; },
      focus() { focused = this; },
    };
  }
  function element(id) {
    const tag = html.match(new RegExp(`<[^>]+\\bid="${id}"[^>]*>`));
    assert.ok(tag, `${language}: missing ${id}`);
    const result = node(tag[0]);
    elements.set(id, result);
    return result;
  }
  const play = element('demo-play');
  const status = element('playback-status');
  play.querySelector = () => ({ setAttribute: (name, value) => { icon = value; } });
  const tabs = ['queue', 'subtitles', 'airplay'].map(name => element(`tab-${name}`));
  const panels = tabs.map(tab => element(tab.attrs['aria-controls']));
  const links = languageTags(html).map(node);
  const scrollTargets = ['<div class="section-heading">', '<article>', '<div class="privacy-card">'].map(node);
  runInNewContext(script, {
    URL,
    window: {
      ...(options.observerSupported ? { IntersectionObserver: class {
        constructor(callback) { revealEntries = callback; }
        observe(target) { observed.add(target); }
        unobserve(target) { observed.delete(target); }
      } } : {}),
      matchMedia: () => ({ matches: !options.reducedMotion }),
      location: {
        href: options.href || `https://beamly.example/site/${language === 'ru' ? 'index' : 'en'}.html`,
        replace: url => redirects.push(url),
      },
      localStorage: {
        getItem(key) { if (options.storageDenied) throw new Error('Storage denied'); return stored.get(key) || null; },
        setItem(key, value) { if (options.storageDenied) throw new Error('Storage denied'); stored.set(key, value); },
      },
    },
    document: {
      documentElement: { lang: language },
      querySelector: selector => elements.get(selector.slice(1)),
      querySelectorAll: selector => selector === '.language-link' ? links : selector === '[role="tab"]' ? tabs : scrollTargets,
      getElementById: id => elements.get(id),
    },
  });
  return { play, status, tabs, panels, links, stored, redirects, scrollTargets, observed,
    reveal: entries => revealEntries(entries), icon: () => icon, focused: () => focused };
}

function assertSelected(ui, index) {
  ui.tabs.forEach((tab, i) => {
    assert.equal(tab.attrs['aria-selected'], String(i === index));
    assert.equal(tab.tabIndex, i === index ? 0 : -1);
    assert.equal(ui.panels[i].hidden, i !== index);
  });
}

for (const language of ['ru', 'en']) {
test(`${language}: demo pause and resume synchronize accessible labels and visible state`, () => {
  const ui = fixture(language);
  const [pause, resume, playing, paused] = playback[language];
  assert.equal(ui.play.attrs['aria-pressed'], 'true');
  assert.equal(ui.play.attrs['aria-label'], pause);
  assert.ok(pages[language].includes(`id="playback-status">${playing}</small>`));
  ui.play.handlers.click();
  assert.equal(ui.play.attrs['aria-pressed'], 'false');
  assert.equal(ui.play.attrs['aria-label'], resume);
  assert.equal(ui.icon(), '#i-play');
  assert.equal(ui.status.textContent, paused);
  ui.play.handlers.click();
  assert.equal(ui.play.attrs['aria-pressed'], 'true');
  assert.equal(ui.play.attrs['aria-label'], pause);
  assert.equal(ui.icon(), '#i-pause');
  assert.equal(ui.status.textContent, playing);
});

test(`${language}: clicked tabs expose only their panel and remain the sole tab stop`, () => {
  const ui = fixture(language);
  assertSelected(ui, 0);
  for (const index of [1, 2, 0]) {
    ui.tabs[index].handlers.click();
    assertSelected(ui, index);
  }
});

test(`${language}: vertical arrows wrap and Home/End focus and select boundary tabs`, () => {
  const ui = fixture(language);
  for (const [from, key, to] of [[0, 'ArrowUp', 2], [2, 'ArrowDown', 0], [0, 'ArrowDown', 1], [1, 'ArrowUp', 0], [0, 'End', 2], [2, 'Home', 0]]) {
    let prevented = false;
    ui.tabs[from].handlers.keydown({ key, preventDefault() { prevented = true; } });
    assert.equal(prevented, true);
    assertSelected(ui, to);
    assert.equal(ui.focused(), ui.tabs[to]);
  }
});

test(`${language}: unhandled keys preserve selection and native behavior`, () => {
  const ui = fixture(language);
  for (const key of ['Tab', 'ArrowLeft', 'ArrowRight', 'Escape', 'Enter', ' ']) {
    ui.tabs[0].handlers.keydown({ key, preventDefault() { assert.fail(`${key} was intercepted`); } });
    assertSelected(ui, 0);
    assert.equal(ui.focused(), undefined);
  }
});

test(`${language}: language links store the selected language without intercepting navigation`, () => {
  const ui = fixture(language);
  assert.equal(ui.links.length, 2);
  for (const link of ui.links) {
    link.handlers.click();
    assert.equal(ui.stored.get('beamly-language'), link.attrs['data-language']);
  }
  assert.deepEqual(ui.redirects, []);
});

test(`${language}: denied storage leaves language links and player controls usable`, () => {
  const ui = fixture(language, { storageDenied: true });
  assert.equal(ui.links.length, 2);
  for (const link of ui.links) assert.doesNotThrow(() => link.handlers.click());
  ui.play.handlers.click();
  assert.equal(ui.play.attrs['aria-pressed'], 'false');
  assert.deepEqual(ui.redirects, []);
});

test(`${language}: scroll reveals start only on entry and stop observing each revealed block`, () => {
  const ui = fixture(language, { observerSupported: true });
  assert.equal(ui.observed.size, ui.scrollTargets.length);
  assert.ok(ui.scrollTargets.every(target => !target.classList.contains('scroll-reveal') && !target.hidden));
  const [first, second, third] = ui.scrollTargets;
  ui.reveal([{ target: first, isIntersecting: false }]);
  assert.equal(first.classList.contains('scroll-reveal'), false);
  assert.equal(ui.observed.size, 3);
  ui.reveal([{ target: first, isIntersecting: true }, { target: second, isIntersecting: false }]);
  assert.equal(first.classList.contains('scroll-reveal'), true);
  assert.equal(ui.observed.has(first), false);
  assert.equal(second.classList.contains('scroll-reveal'), false);
  ui.reveal([{ target: second, isIntersecting: true }, { target: third, isIntersecting: true }]);
  assert.ok(ui.scrollTargets.every(target => target.classList.contains('scroll-reveal') && !target.hidden));
  assert.equal(ui.observed.size, 0);
});

test(`${language}: reduced motion and unavailable observers leave content visible`, () => {
  for (const options of [{ observerSupported: true, reducedMotion: true }, { observerSupported: false }]) {
    const ui = fixture(language, options);
    assert.equal(ui.observed.size, 0);
    assert.ok(ui.scrollTargets.every(target => !target.classList.contains('scroll-reveal') && !target.hidden));
    ui.play.handlers.click();
    assert.equal(ui.play.attrs['aria-pressed'], 'false');
  }
});
}

test('language precedence respects explicit URLs, remembered English, and direct English pages', () => {
  const base = 'https://beamly.example/site/';
  const cases = [
    ['ru', undefined, 'index.html', null],
    ['ru', 'ru', 'index.html', null],
    ['ru', 'en', 'index.html?campaign=launch#features', 'en.html?campaign=launch#features'],
    ['ru', 'en', '?campaign=launch#features', 'en.html?campaign=launch#features'],
    ['ru', 'en', 'index.html?lang=ru#features', null],
    ['ru', 'ru', 'index.html?lang=en&campaign=launch#features', 'en.html?lang=en&campaign=launch#features'],
    ['en', 'ru', 'en.html#download', null],
    ['en', 'en', 'en.html?lang=ru&campaign=launch#download', 'index.html?lang=ru&campaign=launch#download'],
    ['ru', 'fr', 'index.html?lang=fr', null],
    ['en', 'ru', 'en.html?lang=fr', null],
  ];
  for (const [language, saved, path, expected] of cases) {
    const ui = fixture(language, { saved, href: base + path });
    assert.deepEqual(ui.redirects, expected ? [base + expected] : [], `${language}, saved ${saved}, ${path}`);
  }
  const denied = fixture('ru', { storageDenied: true, href: base + 'index.html?lang=en#features' });
  assert.deepEqual(denied.redirects, [base + 'en.html?lang=en#features']);
});

test('both pages declare localized metadata, accessible switchers, and matching interaction IDs', () => {
  for (const language of ['ru', 'en']) {
    const html = pages[language];
    assert.ok(html.includes(`<html lang="${language}">`));
    assert.ok(html.includes(`property="og:locale" content="${language === 'ru' ? 'ru_RU' : 'en_US'}"`));
    assert.match(html, /<title>[^<]+<\/title>/);
    assert.match(html, /<meta name="description" content="[^"]+">/);
    const links = languageTags(html).map(attributes);
    assert.equal(links.length, 2);
    for (const target of ['ru', 'en']) {
      const link = links.find(link => link['data-language'] === target);
      assert.ok(link, `${language}: missing ${target} language link`);
      assert.equal(link.href, `${target === 'ru' ? 'index' : 'en'}.html?lang=${target}`);
      assert.equal(link.lang, target);
      assert.equal(link.hreflang, target);
      assert.equal(link['aria-label'], target === 'ru' ? 'Русский' : 'English');
      assert.equal(link['aria-current'], language === target ? 'page' : undefined);
    }
  }
  const ids = html => [...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]).sort();
  assert.deepEqual(ids(pages.en), ids(pages.ru));
  assert.equal(new Set(ids(pages.en)).size, ids(pages.en).length, 'duplicate IDs');
  assert.doesNotMatch(pages.en.replace('aria-label="Русский"', ''), /[\u0400-\u04ff]/);
  assert.notEqual(pages.en.match(/<title>([^<]+)<\/title>/)[1], pages.ru.match(/<title>([^<]+)<\/title>/)[1]);
});
