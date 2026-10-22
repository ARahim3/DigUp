// Run with node --test shell/tests/*.test.cjs. No browser or model needed.
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

// Exercise the real search functions and input bindings. Only the DOM, clock and
// helper IPC boundary are replaced; requests and rendered replies are observable.
function field(view) {
  const source = readFileSync(join(__dirname, '../ui', `${view}.js`), 'utf8');
  const listeners = new Map(), timers = new Map(), requests = [], visible = [], errors = [];
  const query = { value: '', addEventListener: (type, fn) => listeners.set(type, fn) };
  const elements = new Map([['query', query]]);
  let nextTimer = 0;
  const context = vm.createContext({
    $query: query, $: (id) => {
      if (!elements.has(id)) elements.set(id, {});
      return elements.get(id);
    },
    $kinds: {}, MOD: 'Ctrl+', TYPING_PAUSE: 120, FIELD_HEIGHT: 56, LIMIT: 120, FILTERS: [], FILTER_OF_KIND: {},
    closeBig() {}, renderBar() {}, renderContent() {}, renderStatus() { errors.push('error'); },
    render() { visible.push('render'); }, rows: () => [],
    show(reply) { visible.push(reply); }, failed(error) { errors.push(error); },
    setTimeout(fn) { const id = ++nextTimer; timers.set(id, fn); return id; },
    clearTimeout(id) { timers.delete(id); },
    ask(request) {
      let resolve, reject;
      const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
      requests.push({ ...request, resolve, reject });
      if (request.op !== 'search') resolve({});
      return promise;
    },
  });
  vm.runInContext(source.slice(source.indexOf('const state = {'), source.indexOf('// MARK: Searching')), context);
  const start = source.indexOf(view === 'panel' ? 'function queryChanged(' : 'function isCode(');
  const end = source.indexOf(view === 'panel' ? '\nfunction show(' : '\n/// Every result shown');
  vm.runInContext(source.slice(start, end), context);
  const events = source.indexOf('$query.addEventListener("input"');
  vm.runInContext(source.slice(events, source.indexOf('document.addEventListener("keydown"', events)), context);
  return {
    query, requests, visible, errors,
    event(type, options = {}) { listeners.get(type)?.({ type, ...options }); },
    input(text, options) { query.value = text; this.event('input', options); },
    flush() { const pending = [...timers.values()]; timers.clear(); for (const fn of pending) fn(); },
    programmatic(text) { query.value = text; vm.runInContext('queryChanged()', context); },
    handedOver(text) { query.value = text; context.initialQuery = text; vm.runInContext('state.query = initialQuery; run()', context); },
    submitted() { return vm.runInContext('state.query', context); },
  };
}

test('window: an initial search handed over by the panel can be cleared', () => {
  const f = field('window');
  f.handedOver('dog');
  f.input(''); f.flush();
  assert.equal(f.submitted(), '');
  assert.equal(f.requests.filter(r => r.op === 'search').length, 0);
});

const settle = async () => { for (let i = 0; i < 5; i++) await Promise.resolve(); };
for (const view of ['panel', 'window']) {
  test(`${view}: composition does not search intermediate Japanese text`, () => {
    const f = field(view);
    f.event('compositionstart');
    f.input('とう', { isComposing: true }); f.flush();
    f.input('とうきょう', { isComposing: true }); f.flush();
    assert.equal(f.requests.length, 0);
    assert.equal(f.query.value, 'とうきょう');
  });

  for (const finalInputFirst of [false, true]) {
    test(`${view}: committed text searches once (final input first: ${finalInputFirst})`, () => {
      const f = field(view);
      f.event('compositionstart');
      f.input('とうきょう', { isComposing: true });
      f.query.value = '東京';
      if (finalInputFirst) f.event('input', { isComposing: false });
      f.event('compositionend');
      if (!finalInputFirst) f.event('input', { isComposing: false });
      f.flush();
      assert.deepEqual(f.requests.filter(r => r.op === 'embed_ahead').map(r => r.q), ['東京']);
      assert.deepEqual(f.requests.filter(r => r.op === 'search' && r.meaning).map(r => r.q), ['東京']);
    });
  }

  test(`${view}: composition cancels the previous debounce`, () => {
    const f = field(view);
    f.input('old');
    const before = f.requests.length;
    f.event('compositionstart'); f.flush();
    assert.equal(f.requests.length, before);
  });

  for (const fails of [false, true]) {
    test(`${view}: late ${fails ? 'errors' : 'results'} do not interrupt composition`, async () => {
      const f = field(view);
      f.input('old'); f.flush();
      const pending = f.requests.filter(r => r.op === 'search');
      const before = f.visible.length;
      f.event('compositionstart');
      for (const r of pending) {
        if (fails) r.reject(new Error('old request failed'));
        else r.resolve({ hits: [], strong: 0, meaning: true });
      }
      await settle();
      assert.equal(f.visible.length, before);
      assert.equal(f.errors.length, 0);
    });
  }

  test(`${view}: cancelled composition resumes the previous query`, () => {
    const f = field(view);
    f.input('dog');
    f.event('compositionstart'); f.input('ど', { isComposing: true });
    f.query.value = 'dog'; f.event('compositionend'); f.event('input'); f.flush();
    assert.deepEqual(f.requests.filter(r => r.op === 'search' && r.meaning).map(r => r.q), ['dog']);
  });

  test(`${view}: ordinary typing and programmatic searches still work`, () => {
    const f = field(view);
    f.input('dog'); f.flush();
    f.programmatic('dog'); f.flush();
    assert.deepEqual(f.requests.filter(r => r.op === 'search' && r.meaning).map(r => r.q), ['dog', 'dog']);
    f.input(''); f.flush();
    assert.equal(f.requests.filter(r => r.op === 'search' && r.meaning).length, 2);
  });
}
