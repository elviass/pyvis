const { test } = require('node:test');
const assert = require('node:assert/strict');
const install = require('../client/assets/graph/touch.js');

function touchSurface(title = false) {
  const listeners = {}, taps = [], moves = [], zooms = [];
  let drops = 0;
  const element = {
    getBoundingClientRect: () => ({ left: 10, top: 30 }),
    parentElement: { addEventListener(name, handler, options) {
      assert.equal(options.capture, true);
      listeners[name] = handler;
    } },
    setPointerCapture() {},
  };
  install(element, {
    enabled: () => true, hit: () => ({ title }), world: p => p,
    scale: () => 1, zoom: (...value) => zooms.push(value),
    move: (...value) => moves.push(value), endMove: () => drops++,
    tap: (_, p) => taps.push(p)
  });
  const fire = (type, id, x, y, target = element) => listeners[type]({ type, target, pointerId: id,
    clientX: x, clientY: y, pointerType: 'touch', preventDefault() {}, stopImmediatePropagation() {} });
  return { fire, taps, moves, zooms, drops: () => drops };
}

test('tap tolerance and node-title drag use CSS coordinates at any pixel density', () => {
  const { fire, taps, moves, drops } = touchSurface(true);
  fire('pointerdown', 1, 50, 70); fire('pointermove', 1, 52, 70); fire('pointerup', 1, 52, 70);
  assert.deepEqual(taps, [[42, 40]]);
  fire('pointerdown', 1, 50, 70); fire('pointermove', 1, 70, 80); fire('pointerup', 1, 70, 80);
  assert.deepEqual(moves, [[{ title: true }, 20, 10]]);
  assert.equal(drops(), 1); assert.equal(taps.length, 1);
});

test('pinch preserves its world anchor and lifting a finger continues panning without tapping', () => {
  const { fire, taps, moves, zooms } = touchSurface();
  fire('pointerdown', 1, 30, 50); fire('pointerdown', 2, 70, 50);
  fire('pointermove', 2, 110, 50);
  assert.deepEqual(zooms, [[[40, 20], [60, 20], 2]]);
  fire('pointerup', 2, 110, 50); fire('pointermove', 1, 35, 55);
  fire('pointercancel', 1, 35, 55); fire('lostpointercapture', 1, 35, 55);
  assert.deepEqual(moves, [[null, 5, 5]]); assert.deepEqual(taps, []);
});

test('touches on controls beside the canvas stay with their own buttons', () => {
  const { fire, taps } = touchSurface();
  const button = {};
  fire('pointerdown', 1, 50, 70, button);
  fire('pointerup', 1, 50, 70, button);
  assert.deepEqual(taps, []);
});
