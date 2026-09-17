/* M365 Change Radar - vanilla JS, no build step, no dependencies. */

(() => {
  'use strict';

  const PAGE_SIZE = 60;
  const LAST_VISIT_KEY = 'radar.lastVisit';
  const MOVED_WINDOW_DAYS = 7;
  const RETIREMENT_WINDOW_DAYS = 90;

  const state = {
    q: '',
    product: '',
    windowDays: 30,
    kinds: new Set(),
    statuses: new Set(),
    flags: new Set(),
    page: 1
  };

  let items = [];
  let meta = null;
  let lastVisit = null;
  let baselineFirstSeen = null;
  let filtered = [];

  const el = (id) => document.getElementById(id);

  // ---------- helpers ----------

  const escapeHtml = (value) => String(value ?? '').replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));

  const daysAgo = (days) => Date.now() - days * 86400000;

  // Feed content is third-party. Every interpolated value is escaped, and a link
  // is only rendered as an anchor if it is genuinely http(s).
  function safeUrl(value) {
    try {
      const url = new URL(value);
      return (url.protocol === 'https:' || url.protocol === 'http:') ? url.href : null;
    } catch {
      return null;
    }
  }

  function relativeDate(iso) {
    const then = Date.parse(iso);
    if (Number.isNaN(then)) return '';
    const days = Math.floor((Date.now() - then) / 86400000);
    if (days <= 0) return 'today';
    if (days === 1) return 'yesterday';
    if (days < 30) return `${days}d ago`;
    if (days < 365) return `${Math.floor(days / 30)}mo ago`;
    return `${Math.floor(days / 365)}y ago`;
  }

  // Everything carries the same firstSeen after the seed run, so items stamped
  // with that baseline are backlog, not news.
  const isNew = (item) => Boolean(
    lastVisit &&
    item.firstSeen !== baselineFirstSeen &&
    Date.parse(item.firstSeen) > lastVisit
  );

  function movedRecently(item) {
    const history = item.statusHistory || [];
    if (history.length < 2) return false;
    return Date.parse(history[history.length - 1].seen) > daysAgo(MOVED_WINDOW_DAYS);
  }

  // Source labels are set in config/sources.json; shortened here so the mono
  // metadata rail stays one line at 320px.
  function sourceLabel(item) {
    return (item.product || item.sourceName || '').replace(/^Microsoft\s+/i, '');
  }

  // ---------- URL state ----------

  function readHash() {
    const params = new URLSearchParams(location.hash.replace(/^#/, ''));
    if (!params.toString()) return false;

    state.q = params.get('q') || '';
    state.product = params.get('product') || '';
    state.windowDays = params.has('window') ? Number(params.get('window')) : 30;
    state.kinds = new Set((params.get('kind') || '').split(',').filter(Boolean));
    state.statuses = new Set((params.get('status') || '').split(',').filter(Boolean));
    state.flags = new Set((params.get('flag') || '').split(',').filter(Boolean));
    return true;
  }

  function writeHash() {
    const params = new URLSearchParams();
    if (state.q) params.set('q', state.q);
    if (state.product) params.set('product', state.product);
    if (state.windowDays !== 30) params.set('window', String(state.windowDays));
    if (state.kinds.size) params.set('kind', [...state.kinds].join(','));
    if (state.statuses.size) params.set('status', [...state.statuses].join(','));
    if (state.flags.size) params.set('flag', [...state.flags].join(','));

    const hash = params.toString();
    history.replaceState(null, '', hash ? `#${hash}` : location.pathname);
  }

  function syncControls() {
    el('search').value = state.q;
    el('filter-product').value = state.product;
    el('filter-window').value = String(state.windowDays);

    document.querySelectorAll('.chip').forEach((chip) => {
      const { kind, status, flag } = chip.dataset;
      const active = (kind && state.kinds.has(kind)) ||
                     (status && state.statuses.has(status)) ||
                     (flag && state.flags.has(flag));
      chip.classList.toggle('is-active', Boolean(active));
    });
  }

  // ---------- filtering ----------

  function applyFilters() {
    const q = state.q.trim().toLowerCase();
    const cutoff = state.windowDays > 0 ? daysAgo(state.windowDays) : null;

    filtered = items.filter((item) => {
      if (cutoff && Date.parse(item.published) < cutoff) return false;
      if (state.kinds.size && !state.kinds.has(item.kind)) return false;
      if (state.product && item.product !== state.product) return false;

      // Status and the flags are one OR set, not two AND conditions. They are
      // near-disjoint in the data - 33 of 36 retiring items carry no roadmap
      // status - so intersecting them returns nothing and reads as broken.
      // "Launched + Retiring" means "what shipped, plus what is going away".
      if (state.statuses.size || state.flags.size) {
        const matchesStatus = state.statuses.has(item.status);
        const matchesFlag =
          (state.flags.has('retirement') && item.isRetirement) ||
          (state.flags.has('new') && isNew(item)) ||
          (state.flags.has('moved') && movedRecently(item));
        if (!matchesStatus && !matchesFlag) return false;
      }

      if (q) {
        const haystack = `${item.title} ${item.summary} ${item.product} ${item.sourceName}`.toLowerCase();
        if (!haystack.includes(q)) return false;
      }
      return true;
    });
  }

  // ---------- rendering ----------

  function renderItem(item) {
    // Ledger line: who said it on the left, when and in what state on the
    // right, so the row occupies the full column width instead of trailing off.
    const metaRight = [];
    if (item.isRetirement) metaRight.push('<span class="row__flag">Retiring</span>');
    if (item.status) {
      metaRight.push(`<span class="row__status" data-status="${escapeHtml(item.status)}">${escapeHtml(item.status)}</span>`);
    }
    metaRight.push(`<time class="row__date" datetime="${escapeHtml(item.published)}">${relativeDate(item.published)}</time>`);

    const meta =
      `<span class="row__meta-l"><span class="row__source">${escapeHtml(sourceLabel(item))}</span></span>` +
      `<span class="row__meta-r">${metaRight.join('')}</span>`;

    // Secondary detail: everything that qualifies the change rather than
    // identifying it. Kept as a plain dotted list, not a row of pills.
    const tags = [];
    if (item.targetDate) tags.push(`Target ${escapeHtml(item.targetDate)}`);
    if (movedRecently(item)) {
      const history = item.statusHistory;
      tags.push(`${escapeHtml(history[history.length - 2].status)} &rarr; ${escapeHtml(item.status)}`);
    }
    if (item.sourceName && item.sourceName !== sourceLabel(item)) {
      tags.push(escapeHtml(item.sourceName));
    }
    for (const tag of (item.tags || []).slice(0, 3)) tags.push(escapeHtml(tag));

    const href = safeUrl(item.link);
    const title = href
      ? `<a href="${escapeHtml(href)}" target="_blank" rel="noopener noreferrer">${escapeHtml(item.title)}</a>`
      : escapeHtml(item.title);

    return `
      <article class="row${isNew(item) ? ' is-new' : ''}">
        <div class="row__meta">${meta}</div>
        <div class="row__body">
          <h2 class="row__title">${title}</h2>
          ${item.summary ? `<p class="row__summary">${escapeHtml(item.summary)}</p>` : ''}
          ${tags.length ? `<ul class="row__tags"><li>${tags.join('</li><li>')}</li></ul>` : ''}
        </div>
      </article>`;
  }

  function render() {
    applyFilters();

    const shown = filtered.slice(0, state.page * PAGE_SIZE);
    el('feed').innerHTML = shown.map(renderItem).join('');

    el('result-count').textContent = filtered.length
      ? `Showing ${shown.length} of ${filtered.length} matching updates`
      : '';
    el('empty').hidden = filtered.length > 0;
    el('load-more').hidden = shown.length >= filtered.length;

    writeHash();
    syncControls();
  }

  function renderDigest() {
    const newItems = lastVisit ? items.filter(isNew) : [];
    const moved = items.filter(movedRecently);
    const retirements = items.filter(
      (i) => i.isRetirement && Date.parse(i.published) > daysAgo(RETIREMENT_WINDOW_DAYS)
    );

    el('digest-new').textContent = newItems.length;
    el('digest-moved').textContent = moved.length;
    el('digest-retire').textContent = retirements.length;
    el('digest').hidden = false;
  }

  function renderMeta() {
    if (!meta) return;

    el('meta-lastrun').textContent =
      `updated ${relativeDate(meta.lastRun)} · ${meta.itemCount} items`;

    const failed = (meta.sources || []).filter((s) => s.status === 'failed');
    const health = el('meta-health');
    if (failed.length) {
      health.textContent = `${failed.length} source(s) failing: ${failed.map((s) => s.id).join(', ')}`;
      health.classList.add('is-warning');
    } else {
      health.textContent = `${(meta.sources || []).length} sources healthy`;
      health.classList.remove('is-warning');
    }

    const select = el('filter-product');
    for (const product of meta.products || []) {
      const option = document.createElement('option');
      option.value = product;
      option.textContent = product;
      select.appendChild(option);
    }
  }

  // ---------- events ----------

  function toggle(set, value) {
    if (set.has(value)) { set.delete(value); } else { set.add(value); }
  }

  function bindEvents() {
    let debounce;
    el('search').addEventListener('input', (e) => {
      clearTimeout(debounce);
      debounce = setTimeout(() => {
        state.q = e.target.value;
        state.page = 1;
        render();
      }, 180);
    });

    el('filter-product').addEventListener('change', (e) => {
      state.product = e.target.value;
      state.page = 1;
      render();
    });

    el('filter-window').addEventListener('change', (e) => {
      state.windowDays = Number(e.target.value);
      state.page = 1;
      render();
    });

    el('load-more').addEventListener('click', () => {
      state.page += 1;
      render();
    });

    // `/` focuses search — the one action this page is built around.
    document.addEventListener('keydown', (event) => {
      if (event.key !== '/' || event.metaKey || event.ctrlKey || event.altKey) return;
      const tag = document.activeElement?.tagName;
      if (tag === 'INPUT' || tag === 'SELECT' || tag === 'TEXTAREA') return;
      event.preventDefault();
      el('search').focus();
    });

    el('reset').addEventListener('click', () => {
      state.q = '';
      state.product = '';
      state.windowDays = 30;
      state.kinds.clear();
      state.statuses.clear();
      state.flags.clear();
      state.page = 1;
      render();
    });

    document.addEventListener('click', (event) => {
      const chip = event.target.closest('.chip');
      if (chip) {
        const { kind, status, flag } = chip.dataset;
        if (kind) toggle(state.kinds, kind);
        if (status) toggle(state.statuses, status);
        if (flag) toggle(state.flags, flag);
        state.page = 1;
        render();
        return;
      }

      const digest = event.target.closest('.summary__item');
      if (digest) {
        state.kinds.clear();
        state.statuses.clear();
        state.flags.clear();
        state.q = '';
        state.product = '';

        if (digest.dataset.digest === 'new') {
          state.flags.add('new');
          state.windowDays = 0;
        } else if (digest.dataset.digest === 'moved') {
          state.flags.add('moved');
          state.windowDays = 0;
        } else {
          state.flags.add('retirement');
          state.windowDays = RETIREMENT_WINDOW_DAYS;
        }

        state.page = 1;
        render();
        document.querySelector('.index').scrollIntoView({ block: 'start' });
      }
    });
  }

  // ---------- boot ----------

  async function init() {
    try {
      const stored = localStorage.getItem(LAST_VISIT_KEY);
      lastVisit = stored ? Number(stored) : null;
    } catch {
      lastVisit = null;
    }

    el('result-count').textContent = 'reading feeds…';

    try {
      const [updatesResponse, metaResponse] = await Promise.all([
        fetch('data/updates.json', { cache: 'no-cache' }),
        fetch('data/meta.json', { cache: 'no-cache' })
      ]);

      if (!updatesResponse.ok) throw new Error(`updates.json: HTTP ${updatesResponse.status}`);
      items = await updatesResponse.json();
      if (metaResponse.ok) {
        meta = await metaResponse.json();
        baselineFirstSeen = meta.baselineFirstSeen || null;
      }
    } catch (error) {
      el('result-count').textContent = '';
      el('feed').innerHTML =
        `<article class="row"><div class="row__meta"><span class="row__flag">Error</span></div>
         <div class="row__body"><h2 class="row__title">Could not load update data</h2>
         <p class="row__summary">${escapeHtml(error.message)}</p></div></article>`;
      return;
    }

    renderMeta();
    renderDigest();
    readHash();
    bindEvents();
    render();

    try {
      localStorage.setItem(LAST_VISIT_KEY, String(Date.now()));
    } catch {
      /* private browsing - the new-since marker simply will not persist */
    }
  }

  document.addEventListener('DOMContentLoaded', init);
})();
