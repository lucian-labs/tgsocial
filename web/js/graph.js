/* graph.js — canvas radial graph (PRODUCT §2.7).
 *
 * You = gold dot at the centre, follows = ink dots on ring 1, +1 = faint dots
 * on ring 2, edges = 1px --line. Fixed radial layout, evenly spaced angles,
 * no physics. Tap a dot → profile; drag to pan. Colours and dot sizes come
 * from CSS custom properties read off the canvas element at draw time.
 */

function cssVar(el, name) {
  return getComputedStyle(el).getPropertyValue(name).trim();
}

function cssPx(el, name, fallback) {
  const v = parseFloat(cssVar(el, name));
  return Number.isFinite(v) ? v : fallback;
}

/**
 * mount(canvas, { me, follows, plus, onTap }) → { destroy, update(data) }
 *   me:      { username, name }
 *   follows: [{ username, name }]
 *   plus:    [{ username, name, via: [username] }]
 */
export function mount(canvas, data) {
  const ctx = canvas.getContext('2d');
  let state = { ...data };
  let pan = { x: 0, y: 0 };
  let nodes = [];
  let drag = null;
  let raf = 0;

  function layout(w, h) {
    const cx = w / 2 + pan.x;
    const cy = h / 2 + pan.y;
    const base = Math.min(w, h);
    const r1 = base * 0.27;
    const r2 = base * 0.44;
    const out = [];
    const you = cssPx(canvas, '--app-graph-dot-you', 10) / 2;
    const fol = cssPx(canvas, '--app-graph-dot-follow', 8) / 2;
    const plus = cssPx(canvas, '--app-graph-dot-plus', 6) / 2;
    const me = { ...state.me, x: cx, y: cy, r: you, ring: 0 };
    out.push(me);
    const byUser = new Map();
    const follows = state.follows ?? [];
    follows.forEach((n, i) => {
      const a = -Math.PI / 2 + (i / Math.max(1, follows.length)) * Math.PI * 2;
      const node = { ...n, x: cx + Math.cos(a) * r1, y: cy + Math.sin(a) * r1, r: fol, ring: 1 };
      byUser.set(n.username.toLowerCase(), node);
      out.push(node);
    });
    const plusList = state.plus ?? [];
    plusList.forEach((n, i) => {
      const a = -Math.PI / 2 + ((i + 0.5) / Math.max(1, plusList.length)) * Math.PI * 2;
      const node = { ...n, x: cx + Math.cos(a) * r2, y: cy + Math.sin(a) * r2, r: plus, ring: 2 };
      out.push(node);
    });
    const edges = [];
    for (const n of out) {
      if (n.ring === 1) edges.push([me, n]);
      if (n.ring === 2) for (const v of n.via ?? []) {
        const from = byUser.get(String(v).toLowerCase());
        if (from) edges.push([from, n]);
      }
    }
    nodes = out;
    return { nodes: out, edges };
  }

  function draw() {
    raf = 0;
    const dpr = window.devicePixelRatio || 1;
    const w = canvas.clientWidth;
    const hgt = canvas.clientHeight;
    if (!w || !hgt) return;
    if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(hgt * dpr)) {
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(hgt * dpr);
    }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, hgt);
    const { nodes: ns, edges } = layout(w, hgt);
    const line = cssVar(canvas, '--line') || cssVar(canvas, '--hp-color-line');
    const accent = cssVar(canvas, '--accent');
    const ink = cssVar(canvas, '--ink');
    const faint = cssVar(canvas, '--faint');
    const borderW = cssPx(canvas, '--hp-border-width', 1);
    ctx.lineWidth = borderW;
    ctx.strokeStyle = line;
    ctx.beginPath();
    for (const [a, b] of edges) {
      ctx.moveTo(a.x, a.y);
      ctx.lineTo(b.x, b.y);
    }
    ctx.stroke();
    for (const n of ns) {
      ctx.beginPath();
      ctx.arc(n.x, n.y, n.r, 0, Math.PI * 2);
      ctx.fillStyle = n.ring === 0 ? accent : n.ring === 1 ? ink : faint;
      ctx.fill();
    }
  }

  function schedule() {
    if (!raf) raf = requestAnimationFrame(draw);
  }

  function hit(x, y) {
    const min = cssPx(canvas, '--hp-space-touch-min', 40) / 2;
    let best = null;
    let bestD = Infinity;
    for (const n of nodes) {
      const d = Math.hypot(n.x - x, n.y - y);
      if (d <= Math.max(n.r, min) && d < bestD) {
        best = n;
        bestD = d;
      }
    }
    return best;
  }

  function pos(e) {
    const r = canvas.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  }

  const onDown = (e) => {
    const p = pos(e);
    drag = { start: p, pan: { ...pan }, moved: false, id: e.pointerId };
    canvas.setPointerCapture(e.pointerId);
    canvas.classList.add('dragging');
  };
  const onMove = (e) => {
    if (!drag) return;
    const p = pos(e);
    const dx = p.x - drag.start.x;
    const dy = p.y - drag.start.y;
    if (Math.hypot(dx, dy) > 4) drag.moved = true;
    if (drag.moved) {
      pan = { x: drag.pan.x + dx, y: drag.pan.y + dy };
      schedule();
    }
  };
  const onUp = (e) => {
    if (!drag) return;
    canvas.classList.remove('dragging');
    const p = pos(e);
    const wasTap = !drag.moved;
    drag = null;
    if (wasTap) {
      const n = hit(p.x, p.y);
      if (n && state.onTap) state.onTap(n);
    }
  };
  const onKey = (e) => {
    if (e.key !== 'Enter' || !state.onTap) return;
    const target = nodes.find((n) => n.ring === 1) ?? nodes[0];
    if (target) state.onTap(target);
  };

  canvas.addEventListener('pointerdown', onDown);
  canvas.addEventListener('pointermove', onMove);
  canvas.addEventListener('pointerup', onUp);
  canvas.addEventListener('pointercancel', onUp);
  canvas.addEventListener('keydown', onKey);
  const ro = typeof ResizeObserver !== 'undefined' ? new ResizeObserver(schedule) : null;
  if (ro) ro.observe(canvas);
  schedule();

  return {
    update(next) {
      state = { ...state, ...next };
      schedule();
    },
    destroy() {
      if (ro) ro.disconnect();
      if (raf) cancelAnimationFrame(raf);
      canvas.removeEventListener('pointerdown', onDown);
      canvas.removeEventListener('pointermove', onMove);
      canvas.removeEventListener('pointerup', onUp);
      canvas.removeEventListener('pointercancel', onUp);
      canvas.removeEventListener('keydown', onKey);
    },
  };
}
