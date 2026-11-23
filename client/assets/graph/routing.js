/* Geometry only. The curves and draggable reroutes are drawn by LiteGraph. */
(function (root) {
  'use strict';
  function hit(a, b, r) {
    let enter = 0, leave = 1;
    for (let axis = 0; axis < 2; axis++) {
      const delta = b[axis] - a[axis];
      if (delta === 0) {
        if (a[axis] <= r[axis] || a[axis] >= r[axis + 2]) return false;
        continue;
      }
      const first = (r[axis] - a[axis]) / delta, last = (r[axis + 2] - a[axis]) / delta;
      enter = Math.max(enter, Math.min(first, last));
      leave = Math.min(leave, Math.max(first, last));
      if (enter >= leave) return false;
    }
    return true;
  }
  const clear = (points, obstacles) => points.slice(1).every((b, i) => !obstacles.some(r => hit(points[i], b, r)));
  const overlaps = (a, b) => a[0] <= b[2] && a[2] >= b[0] && a[1] <= b[3] && a[3] >= b[1];
  const laneSpacing = 12;
  const bendCost = 84;
  const distance = (a, b) => Math.abs(a[0] - b[0]) + Math.abs(a[1] - b[1]);
  function segment(a, b) {
    if (a[0] === b[0] && a[1] !== b[1]) return [0, a[0], Math.min(a[1], b[1]), Math.max(a[1], b[1])];
    if (a[1] === b[1] && a[0] !== b[0]) return [1, a[1], Math.min(a[0], b[0]), Math.max(a[0], b[0])];
    return null;
  }
  function laneIndex() {
    const tracks = [new Map(), new Map()];
    const bucket = coordinate => Math.floor(coordinate / laneSpacing);
    return {
      add(points) {
        for (let i = 1; i < points.length; i++) {
          const line = segment(points[i - 1], points[i]);
          if (!line) continue;
          const [axis, coord] = line, key = bucket(coord), index = tracks[axis];
          if (!index.has(key)) index.set(key, []);
          index.get(key).push(line);
        }
      },
      clear(a, b) {
        const line = segment(a, b);
        if (!line) return true;
        const [axis, coord, lo, hi] = line, base = bucket(coord);
        for (let key = base - 1; key <= base + 1; key++) {
          const parallel = tracks[axis].get(key);
          if (parallel?.some(([, used, start, end]) => Math.abs(used - coord) < laneSpacing - .001 &&
              Math.min(hi, end) - Math.max(lo, start) > 0)) return false;
        }
        return true;
      },
      coordinates(bounds) {
        const axes = [new Set(), new Set()];
        for (const [axis, index] of tracks.entries()) {
          const other = 1 - axis, first = bucket(bounds[axis]), last = bucket(bounds[axis + 2]);
          for (const [key, lines] of index) {
            if (key < first || key > last) continue;
            for (const [, coord, start, end] of lines) {
              if (start > bounds[other + 2] || end < bounds[other]) continue;
              axes[axis].add(coord - laneSpacing).add(coord + laneSpacing);
              axes[other].add(start - laneSpacing).add(end + laneSpacing);
            }
          }
        }
        return axes;
      }
    };
  }
  const offset = (a, b) => Math.hypot(b[0] - a[0], b[1] - a[1]) * .25;
  function splineBounds(a, b) {
    const d = offset(a, b);
    return [Math.min(a[0], b[0] - d), Math.min(a[1], b[1]),
      Math.max(a[0] + d, b[0]), Math.max(a[1], b[1])];
  }
  function splineClear(a, b, obstacles) {
    if (!obstacles.length) return true;
    const d = offset(a, b);
    const points = Array.from({ length: 25 }, (_, i) => {
      const t = i / 24, u = 1 - t;
      return [u * u * u * a[0] + 3 * u * u * t * (a[0] + d) + 3 * u * t * t * (b[0] - d) + t * t * t * b[0],
        u * u * (u + 3 * t) * a[1] + t * t * (t + 3 * u) * b[1]];
    });
    return clear(points, obstacles);
  }
  function portLeads(a, b, sourceBox, targetBox) {
    const start = [sourceBox ? Math.max(a[0] + 8, sourceBox[2] + 3) : a[0] + 26, a[1]];
    const end = [targetBox ? Math.min(b[0] - 8, targetBox[0] - 3) : b[0] - 26, b[1]];
    return [start, end];
  }
  function route(a, b, obstacles, sourceBox, targetBox, lanes, bounds) {
    const [start, end] = portLeads(a, b, sourceBox, targetBox);
    const choices = lanes ? [0, laneSpacing, 2 * laneSpacing, 3 * laneSpacing] : [0];
    const fromObstacles = obstacles.filter(r => r !== sourceBox);
    const toObstacles = obstacles.filter(r => r !== targetBox);
    const exits = choices.map(delta => [start[0] + delta, start[1]])
      .filter(point => clear([a, point], fromObstacles));
    const entries = choices.map(delta => [end[0] - delta, end[1]])
      .filter(point => clear([point, b], toObstacles));
    if (!exits.length || !entries.length) return null;
    // Permit brief shared stubs at a port. Reserve lanes beyond the first bend.
    const open = (a, b) => (!lanes || lanes.clear(a, b)) && !obstacles.some(r => hit(a, b, r));
    const fits = path => path.slice(1).every((point, i) => open(path[i], point));
    const mid = (start[0] + end[0]) / 2;
    const elbow = (first, last, x) => simplify([first, [x, first[1]], [x, last[1]], last]);
    if (exits[0][0] === start[0] && entries[0][0] === end[0] && start[0] <= end[0]) {
      const direct = elbow(start, end, mid);
      if (fits(direct)) return direct;
    }
    const [laneXs, laneYs] = lanes?.coordinates(bounds ?? [-Infinity, -Infinity, Infinity, Infinity]) ?? [[], []];
    const ys = [...new Set([start[1], end[1], ...laneYs, ...obstacles.flatMap(r => [r[1] - 8, r[3] + 8])])].sort((x, y) => x - y);
    const centerY = (start[1] + end[1]) / 2;
    const nearbyYs = ys.slice().sort((a, b) => Math.abs(a - centerY) - Math.abs(b - centerY)).slice(0, 12);
    const bypassXs = obstacles.flatMap(r => [r[0] - 8, r[2] + 8]);
    const nearbyXs = [...new Set([...laneXs, ...bypassXs])].sort((a, b) => Math.abs(a - mid) - Math.abs(b - mid)).slice(0, 10);
    let bestPath, bestScore = Infinity;
    for (const first of exits) for (const last of entries) {
      const candidates = [
        ...[mid, last[0], first[0], ...nearbyXs].filter(x => x >= Math.min(first[0], last[0]) && x <= Math.max(first[0], last[0]))
          .map(x => elbow(first, last, x)),
        ...nearbyYs.map(y => simplify([first, [first[0], y], [last[0], y], last]))
      ];
      for (const points of candidates) {
        if (!fits(points)) continue;
        const full = simplify([a, ...points, b]);
        const score = full.slice(1).reduce((sum, next, i) => sum + distance(full[i], next), 0)
          + Math.max(0, full.length - 2) * bendCost;
        if (score >= bestScore) continue;
        bestPath = points;
        bestScore = score;
      }
    }
    if (bestPath) return bestPath;
    // Rectilinear visibility grid; nodes are generated lazily with an A* priority heap.
    // Keep the incoming axis in the search state. Crossing more grid cells on
    // a straight run has no penalty, but each real turn does.
    const xs = [...new Set([...exits.map(p => p[0]), ...entries.map(p => p[0]), mid, ...laneXs, ...bypassXs])].sort((x, y) => x - y);
    const cell = (x, y) => x * ys.length + y;
    const state = (x, y, axis) => 2 * cell(x, y) + axis;
    const point = k => [xs[Math.floor(k / ys.length)], ys[k % ys.length]];
    const targets = new Set(entries.map(([x, y]) => cell(xs.indexOf(x), ys.indexOf(y))));
    const target = entries[0];
    const estimate = (p, axis) => distance(p, target) + distance(target, b)
      + (axis === 1 ? 1 : p[1] === target[1] ? 0 : 2) * bendCost;
    const costs = new Map(), parents = new Map(), heap = [];
    function push(item) {
      heap.push(item); let i = heap.length - 1;
      while (i > 0) { const p = (i - 1) >> 1; if (heap[p][0] <= item[0]) break; heap[i] = heap[p]; i = p; }
      heap[i] = item;
    }
    function pop() {
      const value = heap[0], last = heap.pop();
      if (heap.length) { let i = 0; while (2 * i + 1 < heap.length) {
        let c = 2 * i + 1; if (c + 1 < heap.length && heap[c + 1][0] < heap[c][0]) c++;
        if (heap[c][0] >= last[0]) break; heap[i] = heap[c]; i = c;
      } heap[i] = last; } return value;
    }
    for (const p of exits) {
      const key = state(xs.indexOf(p[0]), ys.indexOf(p[1]), 0), cost = distance(a, p);
      costs.set(key, cost);
      push([cost + estimate(p, 0), key]);
    }
    const visited = new Set();
    while (heap.length && visited.size < 12000) {
      const [, current] = pop(); if (visited.has(current)) continue; visited.add(current);
      const location = Math.floor(current / 2), axis = current % 2;
      if (targets.has(location)) {
        const path = [point(location)]; let p = current;
        while (parents.has(p)) { p = parents.get(p); path.push(point(Math.floor(p / 2))); }
        return simplify(path.reverse());
      }
      const x = Math.floor(location / ys.length), y = location % ys.length, p = point(location);
      for (const [nx, ny] of [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]]) {
        if (nx < 0 || ny < 0 || nx >= xs.length || ny >= ys.length) continue;
        const nextAxis = nx === x ? 1 : 0;
        const next = state(nx, ny, nextAxis), q = [xs[nx], ys[ny]];
        if (visited.has(next) || !open(p, q)) continue;
        const cost = costs.get(current) + distance(p, q) + (nextAxis === axis ? 0 : bendCost);
        if (cost >= (costs.get(next) ?? Infinity)) continue;
        costs.set(next, cost); parents.set(next, current);
        push([cost + estimate(q, nextAxis), next]);
      }
    }
    return null;
  }
  function simplify(points) {
    const unique = points.filter((p, i) => !i || p[0] !== points[i - 1][0] || p[1] !== points[i - 1][1]);
    return unique.filter((p, i) => {
      if (!i || i === unique.length - 1) return true;
      const a = unique[i - 1], b = unique[i + 1];
      return ![0, 1].some(axis => a[axis] === p[axis] && p[axis] === b[axis] &&
        (p[1 - axis] - a[1 - axis]) * (b[1 - axis] - p[1 - axis]) >= 0);
    });
  }
  const api = { route, clear, hit, overlaps, splineBounds, splineClear, laneIndex, portLeads, laneSpacing };
  if (typeof module !== 'undefined') module.exports = api;
  root.PyvisRouting = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
