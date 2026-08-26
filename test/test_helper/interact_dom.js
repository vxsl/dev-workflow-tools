// A DOM small enough to run arcs-page's INTERACT_JS against, and no smaller.
//
// The acknowledgement JS is the one link in the loop that nothing could test. It is not
// browser automation and it must not become that: what it decides is a question about two
// stores and one attribute -- what the page arrived carrying, what this browser has
// clicked, and whether a row renders faded -- and all three are expressible without a
// renderer. So this shims exactly the surface the load path touches and answers every
// selector but `[data-fp]` with nothing, which is a true description of a page that has
// only acknowledgeable rows on it.
//
// The rule it is held to: nothing here may decide anything. The seed, the rows and
// localStorage go in, the real INTERACT_JS runs untouched, and the fade, the stores and the
// published seed come out. A shim that answered a question of its own would be a test of
// itself.

'use strict';
const fs = require('fs');

function extractJS(pagePath) {
  const src = fs.readFileSync(pagePath, 'utf8');
  const m = /^INTERACT_JS = r"""\n([\s\S]*?)^"""$/m.exec(src);
  if (!m) throw new Error('no INTERACT_JS in ' + pagePath);
  return m[1];
}

// `.cls` and `[attr]`, which is every selector this harness has to answer yes to. A
// descendant or compound selector matches nothing, which is correct for a fixture that
// holds no trees, no filings and no curation questions.
function simpleMatch(el, sel) {
  if (/[\s>,]/.test(sel)) return false;
  const m = /^(?:\.([\w-]+)|\[data-([\w-]+)\])$/.exec(sel);
  if (!m) return false;
  if (m[1]) return el.classes.has(m[1]);
  const key = m[2].replace(/-(\w)/g, (_, c) => c.toUpperCase());
  return el.dataset[key] !== undefined;
}

class El {
  constructor(tag, cls) {
    this.tagName = (tag || 'div').toUpperCase();
    this.classes = new Set((cls || '').split(/\s+/).filter(Boolean));
    this.dataset = {};
    this.children = [];
    this.parentNode = null;
    this.textContent = '';
    this.hidden = false;
    this.style = {};
    const self = this;
    this.classList = {
      toggle(c, on) { if (on === undefined) on = !self.classes.has(c);
                      if (on) self.classes.add(c); else self.classes.delete(c); },
      add(c) { self.classes.add(c); },
      remove(c) { self.classes.delete(c); },
      contains(c) { return self.classes.has(c); },
    };
  }
  append(child) { child.parentNode = this; this.children.push(child); return child; }
  closest(sel) {
    let n = this;
    while (n) { if (simpleMatch(n, sel)) return n; n = n.parentNode; }
    return null;
  }
  querySelector() { return null; }
  querySelectorAll() { return []; }
  insertAdjacentElement() {}
  addEventListener() {}
  scrollIntoView() {}
}

// One acknowledgeable row: the fingerprint, whether the build baked it faded, and the ✕
// inside it that a click lands on.
function makeRow(spec) {
  const row = new El('li', 'item');
  row.dataset.fp = spec.fp;
  row.dataset.dismissed = spec.dismissed ? '1' : '0';
  if (spec.ref) row.dataset.ref = spec.ref;
  row.__dis = row.append(new El('button', 'dis'));
  return row;
}

function makeHarness(opts) {
  const rows = (opts.rows || []).map(makeRow);
  const byFp = {};
  rows.forEach(r => { byFp[r.dataset.fp] = r; });
  const seedText = JSON.stringify(opts.seed || {});
  const store = Object.assign({}, opts.storage || {});
  const timers = [];
  let clickHandler = null;
  let published = null;

  const ackseed = new El('script');
  ackseed.dataset.id = 'ackseed';
  ackseed.textContent = seedText;

  const document = {
    getElementById(id) { return id === 'ackseed' ? ackseed : null; },
    querySelectorAll(sel) { return sel === '[data-fp]' ? rows.slice() : []; },
    querySelector() { return null; },
    createElement(tag) { return new El(tag); },
    addEventListener(kind, fn) { if (kind === 'click') clickHandler = fn; },
  };

  // The bytes fetched back at publish time: the runtime's preamble, then this page's own
  // stored markup. Both halves matter -- the cut and the seed swap are the two things
  // publishAcks does to it before it goes out.
  const pageSrc = '<html><head></head><!-- /frame-runtime -->'
    + '<title>Work Arcs</title>'
    + '<script type="application/json" id="ackseed">' + seedText + '</' + 'script>';

  const artifact = {
    publish(next) { published = next; return Promise.resolve(); },
  };

  const sandbox = {
    document,
    location: { href: 'https://example.invalid/page', hash: '' },
    localStorage: {
      getItem(k) { return k in store ? store[k] : null; },
      setItem(k, v) { store[k] = String(v); },
      removeItem(k) { delete store[k]; },
    },
    fetch() { return Promise.resolve({ ok: true, text: () => Promise.resolve(pageSrc) }); },
    setTimeout(fn) { timers.push(fn); return timers.length; },
    clearTimeout(id) { if (id) timers[id - 1] = null; },
    addEventListener() {},
    Promise, JSON, Object, Date, Math, Array, String, Number, parseInt, console,
  };
  sandbox.window = sandbox;
  sandbox.claude = { use(name) {
    return Promise.resolve(name === 'artifact' ? artifact : null); } };

  const flush = () => new Promise(r => setImmediate(r));

  return {
    rows: byFp,
    async load(pagePath) {
      const js = extractJS(pagePath);
      const keys = Object.keys(sandbox);
      // eslint-disable-next-line no-new-func
      new Function(...keys, js)(...keys.map(k => sandbox[k]));
      await flush(); await flush();
    },
    click(fp) {
      if (!clickHandler) throw new Error('no click handler registered');
      clickHandler({ target: byFp[fp].__dis, preventDefault() {}, stopPropagation() {} });
    },
    faded(fp) { return byFp[fp].dataset.dismissed === '1'; },
    read(key) { return key in store ? JSON.parse(store[key]) : null; },
    storage() { return Object.assign({}, store); },
    // Fire the batched publish the way the quiet period would, and hand back the seed that
    // actually went out -- read out of the published bytes, not out of the payload.
    async publish() {
      const due = timers.filter(Boolean);
      timers.length = 0;
      due.forEach(fn => fn());
      await flush(); await flush(); await flush();
      if (published === null) return null;
      const m = /<script type="application\/json" id="ackseed">([\s\S]*?)<\/script>/
        .exec(published);
      return m ? JSON.parse(m[1]) : null;
    },
    publishedBytes() { return published; },
  };
}

module.exports = { makeHarness, extractJS };
