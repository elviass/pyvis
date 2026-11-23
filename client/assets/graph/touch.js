// Keep all gesture coordinates in CSS pixels; the renderer owns device-pixel scaling.
function installGraphTouch(element, view) {
  const fingers = new Map();
  let drag, pinch;
  const point = event => {
    const rect = element.getBoundingClientRect();
    return [event.clientX - rect.left, event.clientY - rect.top];
  };
  const pair = () => {
    const [a, b] = fingers.values();
    return { center: [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2],
      distance: Math.max(1, Math.hypot(b[0] - a[0], b[1] - a[1])) };
  };
  function handle(event) {
    if (event.pointerType !== 'touch' || !view.enabled()) return;
    if (event.type === 'pointerdown' ? event.target !== element : !fingers.has(event.pointerId)) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    const p = point(event), id = event.pointerId;
    if (event.type === 'pointerdown') {
      element.setPointerCapture(id);
      fingers.set(id, p);
      if (fingers.size === 1) {
        drag = { start: p, last: p, hit: view.hit(p), moved: false };
      } else if (fingers.size === 2) {
        if (drag?.moved && drag.hit?.title) view.endMove(drag.hit);
        drag = null;
        const { center, distance } = pair();
        pinch = { anchor: view.world(center), distance, scale: view.scale() };
      }
    } else if (event.type === 'pointermove') {
      fingers.set(id, p);
      if (pinch && fingers.size >= 2) {
        const { center, distance } = pair();
        view.zoom(pinch.anchor, center, pinch.scale * distance / pinch.distance);
      } else if (drag) {
        if (!drag.moved && Math.hypot(p[0] - drag.start[0], p[1] - drag.start[1]) < 6) return;
        drag.moved = true;
        view.move(drag.hit, p[0] - drag.last[0], p[1] - drag.last[1]);
        drag.last = p;
      }
    } else {
      if (drag && event.type === 'pointerup' && !drag.moved) view.tap(drag.hit, p);
      if (drag?.moved && drag.hit?.title) view.endMove(drag.hit);
      fingers.delete(id);
      drag = null;
      pinch = null;
      if (fingers.size >= 2) {
        const { center, distance } = pair();
        pinch = { anchor: view.world(center), distance, scale: view.scale() };
      } else if (fingers.size === 1) {
        const [remaining] = fingers.values();
        drag = { start: remaining, last: remaining, hit: null, moved: true };
      }
    }
  }
  for (const type of ['pointerdown', 'pointermove', 'pointerup', 'pointercancel', 'lostpointercapture']) {
    // Intercept before LiteGraph's capture listeners on the canvas itself.
    element.parentElement.addEventListener(type, handle, { capture: true, passive: false });
  }
}
if (typeof module !== 'undefined') module.exports = installGraphTouch;
