/* ComfyUI's published LiteGraph Canvas2D engine, embedded without a server. */
(function () {
  'use strict';
  const { LGraph, LGraphCanvas, LGraphNode, LGraphGroup, LLink, LinkMarkerShape, RenderShape, LiteGraph } = window.litegraph.js;
  const model = window.PyvisModel, element = document.getElementById('graph');
  const graph = new LGraph();
  const canvas = new LGraphCanvas(element, graph, { autoresize: false, skip_render: true });
  let payload, scene, updating = false, selected, signature;
  let awaitingFrame = false, viewportSize, resizeFrame, failureMessage;
  const nodeMap = new Map(), memories = new Map();
  const linkSpecs = new WeakMap(), highlightedWires = new Set();
  const routing = window.PyvisRouting, hint = document.getElementById('hint');
  let defaultHint = hint.textContent;
  const checkedRoutes = new Set(), blockedRoutes = new Set();
  let occupiedLanes = routing.laneIndex();
  let selectedSpec, saveTimer, routeTimer;
  let autoReroutes = new Set();
  let routesNeedRefresh = false;
  const drawLink = canvas.renderLink.bind(canvas), straightControl = [0, 0];
  canvas.renderLink = (ctx, from, to, link, border, flow, color, start, end, options) => {
    const spec = linkSpecs.get(link);
    if (!spec) {
      drawLink(ctx, from, to, link, border, flow, color, start, end, options);
      return;
    }
    const automatic = autoReroutes.has(options?.reroute?.id) || autoReroutes.has(link.parentId);
    const arrows = canvas.render_connection_arrows, marker = canvas.linkMarkerShape;
    const width = canvas.connections_width, nativeHighlight = canvas.highlighted_links[link.id];
    // LiteGraph replaces highlighted wires with white. Here the color encodes
    // the type, so selection changes the stroke width only.
    if (nativeHighlight) delete canvas.highlighted_links[link.id];
    canvas.connections_width = (spec.execution ? 4 : 2.1) + (highlightedWires.has(link.id) ? 1.4 : 0);
    canvas.render_connection_arrows = spec.execution && !automatic && !options?.reroute;
    canvas.linkMarkerShape = automatic && options?.reroute ? LinkMarkerShape.None
      : spec.execution ? LinkMarkerShape.Arrow : LinkMarkerShape.Circle;
    ctx.save();
    ctx.lineCap = 'round';
    try {
      drawLink(ctx, from, to, link, border, flow, spec.color, start, end,
        automatic ? { ...options, startControl: straightControl, endControl: straightControl } : options);
    } finally {
      ctx.restore();
      canvas.connections_width = width;
      canvas.render_connection_arrows = arrows;
      canvas.linkMarkerShape = marker;
      if (nativeHighlight) canvas.highlighted_links[link.id] = nativeHighlight;
    }
  };
  const bridge = (action, data = {}) => window.flutter_inappwebview?.callHandler('graph', { action, ...data });
  const failure = document.getElementById('failure');
  const fail = (stage, error) => {
    const message = `${stage}失败：${error?.message || error}`;
    if (failureMessage === message) return;
    failureMessage = message;
    console.error(message, error);
    if (window.flutter_inappwebview?.callHandler) {
      bridge('error', { message });
    } else {
      failure.textContent = message;
      failure.hidden = false;
    }
  };
  window.addEventListener('error', event => {
    // A size notification can arrive as a stackless ErrorEvent in an opaque
    // WebKit document. Rendering failures are caught at their source below.
    if (!event.error && (!event.message || event.message.startsWith('ResizeObserver loop') ||
        event.message === 'Script error.' && !event.filename && !event.lineno)) return;
    fail('画布交互', event.error || event.message);
  });
  const draw = canvas.draw.bind(canvas);
  canvas.draw = (...args) => {
    if (!viewportSize) return;
    try {
      draw(...args);
      if (awaitingFrame) {
        awaitingFrame = false;
        failureMessage = null;
        failure.hidden = true;
        bridge('rendered', { nodes: scene.nodes.length, links: scene.links.length, engine: '@comfyorg/litegraph@0.17.2' });
      }
    } catch (error) {
      awaitingFrame = false;
      fail('绘制节点画布', error);
    }
  };
  LiteGraph.NODE_TITLE_HEIGHT = 30;
  LiteGraph.NODE_SLOT_HEIGHT = 24;
  LiteGraph.NODE_TEXT_SIZE = 14;
  LiteGraph.NODE_TITLE_COLOR = '#ddd';
  LiteGraph.NODE_TEXT_COLOR = '#ddd';
  LiteGraph.NODE_DEFAULT_BGCOLOR = '#353535';
  LiteGraph.NODE_DEFAULT_COLOR = '#333';
  LiteGraph.NODE_DEFAULT_BOXCOLOR = '#999';
  canvas.clear_background_color = '#1e1f22';
  canvas.background_image = null;
  canvas.show_info = false;
  canvas.allow_searchbox = false;
  canvas.allow_reconnect_links = false;
  canvas.render_connection_arrows = true;
  canvas.links_render_mode = 2; // ComfyUI SPLINE_LINK
  canvas.render_curved_connections = true;
  canvas.render_connections_border = true;
  canvas.render_shadows = true;
  canvas.ds.min_scale = .08;
  canvas.ds.max_scale = 2.5;
  canvas.default_connection_color_byType = { ...model.colors };
  function typeDot(color) {
    const dot = document.createElement('i');
    dot.className = 'type-dot';
    dot.style.backgroundColor = color;
    dot.setAttribute('aria-hidden', 'true');
    return dot;
  }
  const legend = document.getElementById('legend');
  const flowKey = document.getElementById('flow-key'), typeKey = document.getElementById('type-key');
  for (const [type, label] of Object.entries(model.typeNames)) {
    const flow = type === 'EXEC' || type === 'LOOP' || type === 'EXCEPTION';
    const item = document.createElement('span');
    const swatch = typeDot(model.colors[type]);
    if (flow) swatch.className = 'wire-key';
    item.append(swatch, label);
    (flow ? flowKey : typeKey).appendChild(item);
  }
  document.addEventListener('pointerdown', event => {
    if (legend.open && !legend.contains(event.target)) legend.open = false;
  }, true);
  document.addEventListener('keydown', event => {
    if (legend.open && event.key === 'Escape') legend.open = false;
  });
  // Preserve the native ComfyUI pan/zoom/marquee gesture handling.
  canvas.onDrawBackground = ctx => {
    const [x, y, w, h] = canvas.visible_area;
    const step = canvas.ds.scale < .5 ? 100 : 25;
    ctx.fillStyle = '#303030';
    for (let px = Math.floor(x / step) * step; px < x + w; px += step)
      for (let py = Math.floor(y / step) * step; py < y + h; py += step)
        ctx.fillRect(px, py, 1 / canvas.ds.scale, 1 / canvas.ds.scale);
  };
  canvas.ds.onChanged = scale => {
    document.getElementById('zoom').textContent = `${Math.round(scale * 100)}%`;
    scheduleRoutes();
  };
  function state() {
    return { positions: Object.fromEntries([...nodeMap.values()].map(n =>
      [n.pyvis.key, [n.pos[0] - n.pyvis.base[0], n.pos[1] - n.pyvis.base[1]]])),
      collapsed: [...nodeMap.values()].filter(n => n.flags.collapsed).map(n => n.pyvis.key),
      reroutes: [...graph.reroutes.values()].map(r => r.asSerialisable()),
      linkParents: Object.fromEntries([...graph.links.values()].filter(l=>l.parentId).map(l=>[l.id,l.parentId])),
      autoReroutes: [...autoReroutes], signature, scale: canvas.ds.scale, offset: [...canvas.ds.offset] };
  }
  function remember() {
    const value=state(), previous=memories.get(payload.key);
    value.positions={...previous?.positions,...value.positions};
    memories.set(payload.key,value);
    return value;
  }
  function save() {
    if (!payload || updating) return;
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
      const value = remember();
      bridge('layout', { positions: value.positions });
    }, 60);
  }
  canvas.onNodeMoved = node => {
    if (node) select(node, true);
    for (const member of nodeMap.values()) member.updateArea(canvas.ctx);
    for (const group of graph._groups) group.resizeTo(group.nodes, 32);
    scheduleRoutes(true);
    save();
  };
  function scheduleRoutes(moved = false, delay = 80) {
    routesNeedRefresh ||= moved;
    clearTimeout(routeTimer);
    routeTimer = setTimeout(() => {
      const refresh = routesNeedRefresh;
      routesNeedRefresh = false;
      try {
        routeLinks(refresh);
      } catch (error) {
        fail('整理节点连线', error);
      }
    }, delay);
  }
  function hideAutomaticHandle(reroute) {
    reroute.draw = () => {};
    reroute.drawSlots = () => {};
  }
  function resetRouting() {
    checkedRoutes.clear();
    blockedRoutes.clear();
    occupiedLanes = routing.laneIndex();
    for (const link of graph.links.values()) {
      if (link.parentId) occupiedLanes.add(LLink.getReroutes(graph, link).map(reroute => Array.from(reroute.pos)));
    }
  }
  function routeLinks(moved) {
    if (!scene || !viewportSize || updating) return;
    let changed = false;
    if (moved) {
      for (const id of autoReroutes) graph.removeReroute(id);
      changed = autoReroutes.size > 0;
      autoReroutes = new Set();
      resetRouting();
    }
    const rectangles = new Map([...nodeMap.values()].map(node => {
      const [x, y] = node.pos, [width, height] = node.renderingSize;
      return [node.id, [x - 8, y - LiteGraph.NODE_TITLE_HEIGHT - 8,
        x + width + 8, y + (node.flags.collapsed ? 0 : height) + 8]];
    }));
    const obstacles = [...rectangles.values()];
    const topLeft = canvas.ds.convertCanvasToOffset([0, 0]);
    const bottomRight = canvas.ds.convertCanvasToOffset([element.clientWidth, element.clientHeight]);
    const visible = [topLeft[0] - 300, topLeft[1] - 300, bottomRight[0] + 300, bottomRight[1] + 300];
    const deadline = performance.now() + 12;
    let processed = false;
    for (const edge of scene.links) {
      if (checkedRoutes.has(edge.graphLink)) continue;
      const link = graph.links.get(edge.graphLink);
      if (!link || link.parentId) continue; // Includes manually placed ComfyUI reroutes.
      const source = nodeMap.get(edge.from), target = nodeMap.get(edge.to);
      const a = Array.from(source.getConnectionPos(false, edge.output));
      const b = Array.from(target.getConnectionPos(true, edge.input));
      const hull = routing.splineBounds(a, b);
      if (scene.nodes.length > 180 && !routing.overlaps(visible, hull)) continue;
      if (processed && performance.now() > deadline) {
        scheduleRoutes(false, 16);
        break;
      }
      processed = true;
      checkedRoutes.add(edge.graphLink);
      const fromBox = rectangles.get(source.id), toBox = rectangles.get(target.id);
      const nearby = obstacles.filter(r => r !== fromBox && r !== toBox && routing.overlaps(hull, r));
      if (!edge.backward && b[0] >= a[0] && routing.splineClear(a, b, nearby)) {
        if (a[1] !== b[1]) continue;
        const leads = routing.portLeads(a, b, fromBox, toBox);
        if (leads[0][0] >= leads[1][0]) continue;
        if (occupiedLanes.clear(...leads)) {
          occupiedLanes.add(leads);
          continue;
        }
      }
      const corridor = [hull[0] - 420, hull[1] - 420, hull[2] + 420, hull[3] + 420];
      const relevant = obstacles.filter(r => routing.overlaps(corridor, r));
      const path = routing.route(a, b, relevant, fromBox, toBox, occupiedLanes, corridor);
      if (!path || !routing.clear(path, obstacles)) {
        blockedRoutes.add(edge.graphLink);
        continue;
      }
      occupiedLanes.add(path);
      for (const p of path) {
        const reroute = graph.createReroute(p,link);
        autoReroutes.add(reroute.id);
        hideAutomaticHandle(reroute);
      }
      changed = true;
    }
    hint.textContent = blockedRoutes.size ? '部分连线空间不足，拖开节点可重新绕线。' : defaultHint;
    if (changed) canvas.setDirty(true, true);
  }
  const uiFont = '-apple-system, BlinkMacSystemFont, sans-serif';
  const codeFont = 'ui-monospace, Menlo, monospace';
  function fitText(ctx, text, width) {
    if (ctx.measureText(text).width <= width) return text;
    const characters = Array.from(text);
    let low = 0, high = characters.length;
    while (low < high) {
      const middle = Math.ceil((low + high) / 2);
      if (ctx.measureText(characters.slice(0, middle).join('') + '…').width <= width) low = middle;
      else high = middle - 1;
    }
    return characters.slice(0, low).join('') + '…';
  }
  const drawNode = (spec, node) => ctx => {
    if (node.flags.collapsed) return;
    const [width, height] = node.size, { body, category, mono } = spec.presentation;
    ctx.save();
    if (payload.manualCamera) {
      ctx.strokeStyle = selected === spec.id ? '#86a9e8' : '#59616b';
      ctx.lineWidth = 1 / canvas.ds.scale;
      ctx.beginPath();
      ctx.roundRect(0, -LiteGraph.NODE_TITLE_HEIGHT, width, height + LiteGraph.NODE_TITLE_HEIGHT, LiteGraph.ROUND_RADIUS);
      ctx.stroke();
    }
    ctx.textAlign = 'left'; ctx.textBaseline = 'middle';
    const rows = Math.max(spec.inputSlots.length, spec.outputSlots.length);
    const y = rows * 24 + (node.widgets?.length ? 38 : 0) + 8;
    if (spec.collectionPreview?.length) {
      ctx.fillStyle = '#11151a75';
      ctx.beginPath(); ctx.roundRect(10, y, width - 20, spec.collectionPreview.length * 19 + 8, 5); ctx.fill();
      ctx.font = `12px ${codeFont}`;
      spec.collectionPreview.forEach((row, index) => {
        const x = 17 + row.depth * 13, baseline = y + 14 + index * 19;
        const available = width - x - 17;
        const label = fitText(ctx, row.label, available * .48);
        if (row.depth) {
          ctx.strokeStyle = '#53677a';
          ctx.beginPath(); ctx.moveTo(x - 8, baseline - 10);
          ctx.lineTo(x - 8, baseline); ctx.lineTo(x - 2, baseline); ctx.stroke();
        }
        ctx.fillStyle = '#e3e8ef';
        ctx.fillText(label, x, baseline);
        const left = Math.max(x + ctx.measureText(label).width + 8, width * .48);
        ctx.fillStyle = row.nested ? '#8ed5e7' : '#c1cbd6';
        ctx.fillText(fitText(ctx, row.value, width - left - 15), left, baseline);
      });
    } else if (body) {
      const lines = model.wrap(body, Math.floor((width - 40) / 8), spec.previewLines);
      ctx.fillStyle = '#11151a75';
      ctx.beginPath(); ctx.roundRect(10, y, width - 20, lines.length * 19 + 8, 5); ctx.fill();
      ctx.font = `13px ${mono ? codeFont : uiFont}`;
      ctx.fillStyle = '#e3e8ef';
      lines.forEach((line, index) => ctx.fillText(fitText(ctx, line, width - 36), 18, y + 14 + index * 19));
    }
    ctx.font = `12px ${uiFont}`;
    ctx.fillStyle = node.boxcolor;
    const source = `L${spec.line}${spec.end_line > spec.line ? '–' + spec.end_line : ''}`;
    const origin = spec.origin_line && spec.origin_line !== spec.line ? ` ← L${spec.origin_line}` : '';
    ctx.fillText(fitText(ctx, `${category} · ${source}${origin}`, width - 24), 12, height - 13);
    ctx.restore();
  };
  function portName(label, spec, opposingCount, index) {
    const ctx = canvas.ctx;
    ctx.save(); ctx.font = canvas.inner_text_font;
    const width = opposingCount > index ? (spec.width - 44) / 2 : spec.width - 34;
    const name = fitText(ctx, label, width);
    ctx.restore();
    return name;
  }
  function makeNode(spec) {
    const { caption, palette } = spec.presentation;
    const node = new LGraphNode(caption);
    node.pyvis = spec;
    node.mode = 2; // NEVER: Python is the only execution engine.
    node.pos = [spec.x, spec.y];
    node.shape = 2;
    node.color = palette.header;
    node.bgcolor = palette.body;
    node.boxcolor = model.colors[spec.value_type || spec.literal_type] || palette.accent;
    node.onDrawTitleText = (ctx, height, size, scale) => {
      if (scale < .42) return;
      ctx.save();
      ctx.font = `600 15px ${spec.kind === 'literal' ? codeFont : uiFont}`;
      ctx.fillStyle = '#f3f5f9'; ctx.textAlign = 'left'; ctx.textBaseline = 'middle';
      ctx.fillText(fitText(ctx, caption, size[0] - 42), 29, -height / 2 + 1);
      ctx.restore();
    };
    spec.inputSlots.forEach((s, index) => {
      node.addInput(portName(s.label, spec, spec.outputSlots.length, index), s.type,
        { shape: s.execution ? RenderShape.ARROW : RenderShape.CIRCLE, color_on: s.color, color_off: s.color });
    });
    spec.outputSlots.forEach((s, index) => {
      node.addOutput(portName(s.label, spec, spec.inputSlots.length, index), s.type,
        { shape: s.execution ? RenderShape.ARROW : RenderShape.CIRCLE, color_on: s.color, color_off: s.color });
    });
    node.onDrawForeground = drawNode(spec, node);
    if (spec.collectionEntry) {
      node.addWidget('button', `查看元素 · ${spec.detailCount} 个节点`, null, () => activate(spec));
    } else if (spec.kind === 'section') {
      const child = spec.section.subflow_group;
      const count = child ? spec.section.subflow_nodes
        : payload.nodes.filter(n => n.section_id === spec.id).length;
      node.addWidget('button', child ? `进入子流程 · ${spec.section.subflow_sections} 个代码块`
        : `展开 · ${count} 个节点`, null, () => activate(spec));
    } else if (spec.collectionPreview?.length) {
      node.addWidget('button', '查看结构', null, () => select(node, true));
    }
    node.size = [spec.width, Math.max(spec.height, node.computeSize()[1])];
    node.onDblClick = () => activate(spec);
    graph.add(node); nodeMap.set(spec.id, node);
    return node;
  }
  function activate(spec) {
    select(nodeMap.get(spec.id), true);
    if (spec.collectionEntry) bridge('detail', { id: spec.id, section: spec.section_id, line: spec.line });
    else if (spec.kind === 'section') bridge(spec.section.subflow_group ? 'enter' : 'fold',
      { id: spec.id, group: spec.section.subflow_group, line: spec.line });
    else if (spec.kind === 'call' || spec.kind === 'definition') bridge('call', { id: spec.id, line: spec.line });
  }
  function showCollection(parent, shape) {
    const rows = document.createElement('ul');
    rows.className = 'structure-rows';
    for (const row of shape.rows) {
      const item = document.createElement('li');
      item.className = 'structure-row';
      const label = document.createElement('span');
      label.className = 'structure-key';
      label.textContent = row.label;
      const nested = payload.collections?.[row.collection];
      if (nested) {
        const branch = document.createElement('details');
        const summary = document.createElement('summary');
        summary.append(label, `  ${nested.type} · ${nested.rows.length} 项`);
        branch.appendChild(summary);
        branch.addEventListener('toggle', () => {
          if (branch.open && branch.childElementCount === 1) showCollection(branch, nested);
        });
        item.appendChild(branch);
      } else {
        const value = document.createElement('span');
        value.className = 'structure-leaf';
        value.textContent = row.code;
        item.append(label, value);
      }
      rows.appendChild(item);
    }
    parent.appendChild(rows);
  }
  function select(node, notify, showInspector = true) {
    if (!node) return;
    selected = node.pyvis.id; selectedSpec = node.pyvis;
    highlightedWires.clear();
    if (showInspector) {
      const focus = model.connected(selected, scene.links);
      for (const edge of scene.links) {
        const related = edge.execution ? edge.from === selected || edge.to === selected
          : focus.has(edge.from) && focus.has(edge.to);
        if (related) highlightedWires.add(edge.graphLink);
      }
    }
    const p = selectedSpec, inspector = document.getElementById('inspector');
    inspector.hidden = !showInspector;
    document.getElementById('selection-title').textContent = `L${p.line} · ${p.presentation.caption}`;
    const shape = payload.collections?.[p.collectionId];
    const code = document.getElementById('selection-code');
    code.hidden = Boolean(shape);
    code.textContent = shape ? '' : p.code || p.detail || '';
    document.getElementById('selection-help').textContent = [p.presentation.category,
      p.section?.teaching?.explanation || p.reference_label || p.role].filter(Boolean).join(' · ');
    const action = document.getElementById('selection-action');
    const label = p.collectionEntry ? '查看集合元素'
      : p.kind === 'section' ? (p.section.subflow_group ? '进入子流程' : '展开代码块')
      : p.kind === 'call' ? '查看调用' : null;
    action.hidden = !payload.manualCamera || !label;
    if (!action.hidden) action.textContent = label;
    const origin = document.getElementById('selection-origin');
    origin.hidden = !p.origin_line;
    if (p.origin_line) origin.textContent = `定位变量来源 · L${p.origin_line}`;
    const structure = document.getElementById('selection-structure');
    structure.replaceChildren();
    if (showInspector && shape) showCollection(structure, shape);
    const ports = document.getElementById('selection-connections');
    ports.replaceChildren();
    for (const edge of showInspector ? scene.links : []) {
      if (edge.from !== p.id && edge.to !== p.id) continue;
      const incoming = edge.to === p.id;
      const other = nodeMap.get(incoming ? edge.from : edge.to);
      const button = document.createElement('button');
      const port = incoming ? p.inputSlots[edge.input] : p.outputSlots[edge.output];
      const direction = incoming ? '来源' : '去向';
      const typeLabel = edge.execution ? '' : `（${model.typeNames[port.type]}）`;
      button.append(typeDot(port.color),
        `${direction} · ${port.label}${typeLabel} → L${other.pyvis.line} ${other.pyvis.presentation.caption}`);
      button.title = button.textContent;
      button.onclick = () => {
        canvas.deselectAllNodes();
        select(other, true);
        command('readable');
      };
      ports.appendChild(button);
    }
    if (notify) bridge('select', { id: p.id, line: p.line });
    canvas.setDirty(true, true);
  }
  canvas.onNodeSelected = node => { if (!updating) select(node, true); };
  function clearSelection() {
    selected = null;
    highlightedWires.clear();
    selectedSpec = null;
    document.getElementById('inspector').hidden = true;
    canvas.setDirty(true, true);
  }
  canvas.onNodeDeselected = () => {
    if (!Object.keys(canvas.selected_nodes || {}).length) clearSelection();
  };
  document.getElementById('selection-origin').onclick = () => bridge('source', { line: selectedSpec.origin_line });
  canvas.getNodeMenuOptions = node => [
    { content: '定位代码', callback: () => select(node, true) },
    node.pyvis.collectionEntry ? { content: '查看集合元素', callback: () => activate(node.pyvis) }
    : node.pyvis.kind === 'section'
      ? { content: node.pyvis.section.subflow_group ? '进入子流程' : '展开代码块', callback: () => activate(node.pyvis) }
      : { content: node.flags.collapsed ? '展开节点' : '折叠节点', callback: () => { node.collapse(); scheduleRoutes(true); save(); } },
    node.pyvis.section_id ? { content: '折叠所属代码块', callback: () => bridge('fold', { id: node.pyvis.section_id }) } : null,
    node.pyvis.origin_line ? { content: `定位变量来源 · L${node.pyvis.origin_line}`, callback: () => bridge('source', { line: node.pyvis.origin_line }) } : null
  ].filter(Boolean);
  canvas.getCanvasMenuOptions = () => [
    { content: '恢复可读字号', callback: () => command('readable') },
    { content: '查看全图', callback: () => command('fit') },
    { content: '展开本层代码块', callback: () => bridge('expandAll') },
    { content: '折叠本层代码块', callback: () => bridge('collapseAll') },
    { content: '恢复自动布局', callback: () => command('reset') }
  ];
  canvas.showLinkMenu = (segment, event) => {
    new LiteGraph.ContextMenu([{ content:'添加转接点', callback:() => {
      graph.createReroute([event.canvasX,event.canvasY],segment); scheduleRoutes(true); save();
    } }], { event, className:'dark' });
    return true;
  };
  document.getElementById('selection-action').onclick = () => { if (selectedSpec) activate(selectedSpec); };
  document.getElementById('close-inspector').onclick = clearSelection;
  installGraphTouch(element, {
    enabled: () => payload?.manualCamera,
    scale: () => canvas.ds.scale,
    world: point => canvas.ds.convertCanvasToOffset(point),
    hit(point) {
      const [x, y] = canvas.ds.convertCanvasToOffset(point);
      const node = graph.getNodeOnPos(x, y);
      return node ? { node, title: y < node.pos[1] } : null;
    },
    move(hit, dx, dy) {
      const position = hit?.title ? hit.node.pos : canvas.ds.offset;
      position[0] += dx / canvas.ds.scale;
      position[1] += dy / canvas.ds.scale;
      if (hit?.title) hit.node.updateArea(canvas.ctx);
      else scheduleRoutes();
      canvas.setDirty(true, true);
    },
    endMove(hit) { canvas.onNodeMoved(hit.node); },
    zoom(anchor, center, target) {
      const scale = Math.max(canvas.ds.min_scale, Math.min(canvas.ds.max_scale, target));
      canvas.ds.scale = scale;
      canvas.ds.offset = [center[0] / scale - anchor[0], center[1] / scale - anchor[1]];
      canvas.ds.onChanged(scale);
      canvas.setDirty(true, true);
    },
    tap(hit, point) {
      if (!hit) { clearSelection(); return; }
      const [x, y] = canvas.ds.convertCanvasToOffset(point);
      if (hit.node.getWidgetOnPos(x, y)) activate(hit.node.pyvis);
      else select(hit.node, true);
    }
  });
  // AST links are semantic facts, never graph edits. Keep movement, groups, and reroutes native.
  element.addEventListener('pointerdown', event => {
    const box = element.getBoundingClientRect();
    const point = canvas.ds.convertCanvasToOffset([event.clientX - box.left, event.clientY - box.top]);
    const node = graph.getNodeOnPos(point[0], point[1]);
    if (node?.getSlotInPosition(point[0], point[1])) {
      event.stopImmediatePropagation(); event.preventDefault(); select(node, true);
    }
  }, true);
  element.addEventListener('keydown', event => {
    if (['Delete', 'Backspace'].includes(event.key) || ((event.metaKey || event.ctrlKey) && ['v', 'x', 'd'].includes(event.key.toLowerCase()))) {
      event.preventDefault(); event.stopImmediatePropagation();
    }
    if (event.key === 'Escape') { canvas.deselectAllNodes(); clearSelection(); }
  }, true);
  element.addEventListener('pointerup', () => setTimeout(save, 0));
  function readable() {
    const node = nodeMap.get(selected) || [...nodeMap.values()].find(n => n.pyvis.line === payload?.activeLine) || nodeMap.values().next().value;
    const camera = model.readableCamera({nodes:[...nodeMap.values()].map(n=>({...n.pyvis,x:n.pos[0],y:n.pos[1],height:n.size[1]}))},
      node ? {x:node.pos[0],y:node.pos[1]} : null,element.clientWidth,element.clientHeight);
    canvas.ds.scale = camera.scale;
    canvas.ds.offset = payload.manualCamera && node
      ? [Math.max(18, (element.clientWidth - node.size[0] * camera.scale) / 2) / camera.scale - node.pos[0],
          20 / camera.scale + LiteGraph.NODE_TITLE_HEIGHT - node.pos[1]]
      : camera.offset;
    canvas.setDirty(true, true);
  }
  function command(action) {
    if (action === 'in' || action === 'out') canvas.ds.changeScale(canvas.ds.scale * (action === 'in' ? 1.2 : 1 / 1.2));
    else if (action === 'readable') readable();
    else if (action === 'fit' && nodeMap.size) {
      const ns = [...nodeMap.values()];
      const x = Math.min(...ns.map(n => n.pos[0])) - 50, y = Math.min(...ns.map(n => n.pos[1])) - 80;
      const right = Math.max(...ns.map(n => n.pos[0] + n.size[0])) + 50;
      const bottom = Math.max(...ns.map(n => n.pos[1] + n.size[1])) + 50;
      const scale=Math.max(.08,Math.min(1,(element.clientWidth-80)/(right-x),(element.clientHeight-140)/(bottom-y)));
      canvas.ds.scale=scale;
      canvas.ds.offset=[element.clientWidth/(2*scale)-(x+right)/2,
        (element.clientHeight+60)/(2*scale)-(y+bottom)/2];
    } else if (action === 'reset') {
      memories.delete(payload.key); bridge('reset'); receive({ ...payload, positions: {}, resetCamera: true });
    }
    canvas.setDirty(true, true);
    document.getElementById('zoom').textContent = `${Math.round(canvas.ds.scale * 100)}%`;
  }
  for (const button of document.querySelectorAll('[data-action]')) button.onclick = () => command(button.dataset.action);
  function receive(next) {
    awaitingFrame = false;
    try {
      if (payload && !next.resetCamera) remember();
      const same = payload?.key === next.key, memory = next.resetCamera ? null : memories.get(next.key);
      if (next.manualCamera && !document.body.classList.contains('mobile-graph')) {
        document.body.classList.add('mobile-graph');
        document.getElementById('tools').appendChild(legend);
        // Paint wires and node outlines on the same backing surface and transform.
        canvas.bgcanvas = element;
        canvas.bgctx = canvas.ctx;
        canvas.render_canvas_border = false;
        canvas.render_connections_border = false;
        canvas.render_shadows = false;
        resizeCanvas();
      }
      payload = next; updating = true; graph.clear(); nodeMap.clear();
      selected = null; autoReroutes = new Set();
      highlightedWires.clear();
      if (next.manualCamera) defaultHint = '单指平移 · 双指缩放 · 点按展开按钮进入代码块';
      hint.textContent = defaultHint;
      document.getElementById('inspector').hidden = true;
      scene = model.buildScene({ ...payload,
        portraitLayout: next.manualCamera && element.clientWidth < element.clientHeight,
        positions: { ...payload.positions, ...memory?.positions } });
      signature = JSON.stringify([scene.nodes.map(n => [n.id, n.base, n.width, n.height]), scene.links]);
      const collapsed = new Set(memory?.collapsed);
      const membersBySection = new Map();
      for (const spec of scene.nodes) {
        const node = makeNode(spec);
        if (collapsed.has(spec.key)) node.collapse();
        if (spec.section_id != null) {
          if (!membersBySection.has(spec.section_id)) membersBySection.set(spec.section_id, []);
          membersBySection.get(spec.section_id).push(node);
        }
      }
      for (const edge of scene.links) {
        const link = nodeMap.get(edge.from).connect(edge.output, nodeMap.get(edge.to), edge.input);
        if (!link) throw Error(`端口连接失败：${edge.from} → ${edge.to}`);
        link.color = edge.color;
        linkSpecs.set(link, edge);
        edge.graphLink = link.id;
      }
      for (const spec of scene.groups) {
        const group = new LGraphGroup(spec.title);
        group.color = '#59616a'; group.font_size = 18;
        graph.add(group);
        const members = membersBySection.get(spec.id) || [];
        for(const node of members) node.updateArea(canvas.ctx);
        group.resizeTo(members, 32);
        group.recomputeInsideNodes();
        group.getMenuOptions = () => [{ content: '折叠代码块', callback: () => bridge('fold', { id: spec.id }) }];
      }
      if (memory) {
        // Reroutes address links by generated engine IDs, so restore only an unchanged scene.
        if (same && memory.signature === signature) {
          for (const r of memory.reroutes || []) graph.setReroute(r);
          for (const [id,parent] of Object.entries(memory.linkParents || {})) {
            const link=graph.links.get(Number(id)); if(link) link.parentId=parent;
          }
          autoReroutes = new Set(memory.autoReroutes || []);
          for (const id of autoReroutes) {
            const reroute = graph.getReroute(id);
            if (reroute) hideAutomaticHandle(reroute);
          }
        }
        canvas.ds.scale = memory.scale; canvas.ds.offset = memory.offset;
      } else if (next.manualCamera && !next.detailId && !next.activeLine) {
        command('fit');
        if (canvas.ds.scale < .6) readable();
      } else readable();
      resetRouting();
      const focusTarget = scene.detail && !next.focusId
        ? scene.nodes.slice().sort((a, b) => a.x - b.x || a.y - b.y)[0]
        : model.focusNode(scene, next.focusId, next.activeLine);
      if (focusTarget) {
        select(nodeMap.get(focusTarget.id), false, false);
        if (next.reveal && (!next.manualCamera || (!memory && (next.activeLine || next.detailId)))) readable();
      }
      updating = false;
      scheduleRoutes();
      awaitingFrame = true;
      canvas.setDirty(true, true);
      document.getElementById('zoom').textContent = `${Math.round(canvas.ds.scale * 100)}%`;
    } catch (error) {
      updating = false;
      awaitingFrame = false;
      fail('生成节点画布', error);
    }
  }
  function resizeCanvas() {
    resizeFrame = null;
    const width = element.clientWidth, height = element.clientHeight;
    if (!width || !height) {
      viewportSize = null;
      return;
    }
    const ratio = Math.max(1, window.devicePixelRatio || 1);
    if (viewportSize?.[0] === width && viewportSize[1] === height && viewportSize[2] === ratio) return;
    try {
      canvas.resize(Math.round(width * ratio), Math.round(height * ratio));
      // The engine works in CSS pixels, with Retina scaling on both contexts.
      canvas.viewport = [0, 0, width, height];
      canvas.ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
      canvas.bgcanvas.getContext('2d').setTransform(ratio, 0, 0, ratio, 0, 0);
      viewportSize = [width, height, ratio];
      canvas.setDirty(true, true);
      if (scene) scheduleRoutes();
    } catch (error) {
      fail('调整画布大小', error);
    }
  }
  // The canvas fills its webview. Resize the backing store after the viewport
  // changes, outside WebKit's ResizeObserver delivery phase.
  window.addEventListener('resize', () => {
    if (resizeFrame == null) resizeFrame = requestAnimationFrame(resizeCanvas);
  });
  window.PyvisCanvas = { receive, command, snapshot: () => ({ ...state(),
    nodes: scene?.nodes.map(n => ({ id: n.id, line: n.line, kind: n.kind,
      caption: n.presentation.caption })), links: scene?.links.length }) };
  bridge('ready');
  resizeCanvas();
  canvas.startRendering();
})();
