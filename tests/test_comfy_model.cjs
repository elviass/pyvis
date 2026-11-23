// Real Python AST -> adapter -> actual published ComfyUI LiteGraph graph.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const model = require('../client/assets/graph/model.js');
const routing = require('../client/assets/graph/routing.js');
const context = { console, EventTarget, CustomEvent, crypto, performance,
  setTimeout, clearTimeout, window: {}, document: {}, navigator: { platform: 'MacIntel' } };
vm.createContext(context);
vm.runInContext(fs.readFileSync(path.join(root, 'client/assets/graph/vendor/litegraph.umd.js'), 'utf8'), context);
const engine = context.litegraph.js;
function parse(source) {
  const p = spawnSync('python3', ['-c', 'import sys,json; from pyvis_runtime.blueprint import code_graph; print(json.dumps(code_graph(sys.stdin.read())))'],
    { input: source, cwd: root, env: { ...process.env, PYTHONPATH: 'runtime' }, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
  assert.equal(p.status, 0, p.stderr);
  return JSON.parse(p.stdout);
}
function payload(graph, folded = false) {
  const view = graph.whole_views[0];
  return { ...view, tree: view.flow_tree, collections: graph.collections,
    folded: folded ? view.sections.map(s => s.id) : [] };
}
function realEngine(scene) {
  const graph = new engine.LGraph(), lookup = new Map();
  for (const spec of scene.nodes) {
    const n = new engine.LGraphNode(spec.title);
    n.mode = 2;
    for (const s of spec.inputSlots) n.addInput(s.label, s.type);
    for (const s of spec.outputSlots) n.addOutput(s.label, s.type);
    graph.add(n); lookup.set(spec.id, n);
  }
  for (const edge of scene.links) {
    const link = lookup.get(edge.from).connect(edge.output, lookup.get(edge.to), edge.input);
    assert.ok(link, `${edge.from} -> ${edge.to}`);
  }
  assert.equal(graph.links.size, scene.links.length, 'merges must retain every incoming edge');
  assert.equal(graph.status, engine.LGraph.STATUS_STOPPED, 'the display must never execute user code');
  return graph;
}
test('uses the unmodified ComfyUI engine and preserves every atomic entity', () => {
  const ast = parse('a=20\nb=3\nx=a*b\nprint(x)\n');
  const data = payload(ast), scene = model.buildScene(data);
  assert.deepEqual(scene.nodes.map(n => n.id).sort(), data.nodes.map(n => n.id).sort());
  assert.ok(scene.nodes.find(n => n.kind === 'reference' && n.origin_line === 1));
  assert.ok(scene.nodes.some(n => n.kind === 'write'));
  assert.ok(scene.nodes.some(n => n.kind === 'operator'));
  realEngine(scene);
});
test('typed data ports and execution ports stay distinct, including parallel predecessors', () => {
  const ast = parse('n=4\nif n>2:\n    x=1\nelse:\n    x=2\nprint(x)\n');
  const data = payload(ast, true), scene = model.buildScene(data);
  const labels = scene.links.filter(e => e.execution).map(e => e.label);
  assert.ok(labels.includes('成立'));
  assert.ok(labels.includes('不成立'));
  assert.equal(scene.links.length, data.section_links.length);
  assert.ok(scene.nodes.some(n => n.inputSlots.filter(s => s.execution).length > 1));
  realEngine(scene);
  const expanded = model.buildScene(payload(ast));
  assert.ok(expanded.links.some(e => e.type === 'int'));
  assert.ok(expanded.links.some(e => e.type === 'EXEC'));
  realEngine(expanded);
});
test('wire and endpoint colors carry inferred values through bindings and distinguish dictionary entries', () => {
  const ast = parse(`count = 500
amount = (count + 2) / 2
data = {"name": "水杯", "quantity": count, "amount": amount, "enabled": count > 1,
        "nested": [None, {"x": (1, 2)}]}
if mystery:
    selected = 1
else:
    selected = "text"
print(data, selected)
`);
  for (const compactNodes of [false, true]) {
    const options = { ...payload(ast), compactNodes };
    const scene = model.buildScene(options);
    const byId = new Map(scene.nodes.map(n => [n.id, n]));
    const findEntry = (graph, name) => graph.nodes.find(n => n.kind === 'element' && n.entry_key === `"${name}"`);
    const details = node => model.buildScene({ ...options, detailId: node.id });
    const entryType = (name, type) => {
      const overview = findEntry(scene, name);
      const node = overview?.collectionEntry ? findEntry(details(overview), name)
        : overview || findEntry(details(findEntry(scene, 'nested')), name);
      assert.equal(node.inputSlots.find(p => p.label === '键').type, 'str');
      assert.equal(node.inputSlots.find(p => p.label === '值').type, type);
      assert.ok((overview ?? node).outputSlots.some(p => p.type === 'dict_entry' && p.label === '键值对'));
    };
    for (const [name, type] of [['name', 'str'], ['quantity', 'int'], ['amount', 'float'],
      ['enabled', 'bool'], ['nested', 'list'], ['x', 'tuple']]) entryType(name, type);
    const readType = name => scene.nodes.find(n => n.kind === 'read' && n.symbol === name).outputSlots[0].type;
    assert.equal(readType('data'), 'dict');
    assert.equal(readType('selected'), 'DATA');
    for (const edge of scene.links) {
      assert.equal(edge.color, byId.get(edge.from).outputSlots[edge.output].color);
      assert.equal(edge.color, byId.get(edge.to).inputSlots[edge.input].color);
    }
    realEngine(scene);
  }
});
test('compact rows label actual work, preserve operand order and link to source lines', () => {
  const ast = parse('price=20\ncount=3\ntotal=price*count\nvalid=price < total <= 100\n');
  const data = ast.line_views.find(view => view.line === 3);
  const scene = model.buildScene({ ...data, compactNodes: true });
  assert.deepEqual(scene.nodes.map(n => n.presentation.caption),
    ['读取 price', '读取 count', '乘法 ×', '写入 total', 'total']);
  const [left, right, operator, write, variable] = scene.nodes;
  assert.deepEqual([left.origin_line, right.origin_line], [1, 2]);
  assert.equal(operator.presentation.body, 'price*count');
  assert.deepEqual(operator.inputSlots.map(s => s.label), ['左侧', '右侧']);
  assert.ok(scene.links.some(e => e.from === operator.id && e.to === write.id));
  assert.ok(Math.max(left.x, right.x) < operator.x && operator.x < write.x && write.x < variable.x);
  assert.ok(scene.links.every(e => !e.connector));
  const camera = model.readableCamera(scene, left, 920, 620);
  assert.ok(camera.scale >= .85 && (variable.x + variable.width + camera.offset[0]) * camera.scale <= 920);
  const relay = data.nodes.find(n => n.kind === 'value');
  assert.equal(model.focusNode(scene, relay.id, 3).id, left.id);
  const moved = model.buildScene({ ...data, compactNodes: true, positions: { [left.key]: [42, 15] } });
  assert.deepEqual(moved.links, scene.links);
  assert.equal(moved.nodes[0].x, left.x + 42);
  const comparison = model.buildScene({ ...ast.line_views.find(v => v.line === 4), compactNodes: true });
  assert.ok(comparison.nodes.some(n => n.presentation.caption === '小于 <' && n.presentation.body === 'price < total'));
  assert.ok(comparison.nodes.some(n => n.presentation.caption === '小于等于 ≤' && n.presentation.body === 'total ≤ 100'));
  assert.deepEqual(comparison.nodes.find(n => n.operator === 'LtE').inputSlots.filter(s => !s.execution).map(s => s.label),
    ['左侧', '右侧']);
  realEngine(scene);
  realEngine(comparison);
});
test('flow layout follows paths; branches use separate lanes and the join follows both', () => {
  const ast = parse('n=4\nif n>2:\n    x=1\nelse:\n    x=2\nprint(x)\n');
  const scene = model.buildScene(payload(ast, true));
  const yes = scene.nodes.find(n => n.line === 3), no = scene.nodes.find(n => n.line === 5);
  assert.notEqual(yes.y, no.y);
  assert.equal(yes.x, no.x);
  const merged = scene.nodes.find(n => n.section?.category === 'Join');
  assert.ok(merged.x > yes.x && merged.x > no.x);
});
test('menu, nested exceptions, recursion, and loops render without dropping nodes or links', () => {
  const sources = [fs.readFileSync(path.join(root, 'tests/fixtures/menu_decimal.py'), 'utf8'),
    'def f(n):\n    if n<=1:\n        return 1\n    return n*f(n-1)\nprint(f(4))\n',
    'while True:\n    x=input()\n    if x=="q":\n        break\n    try:\n        int(x)\n    except ValueError:\n        continue\n    finally:\n        print(x)\n'];
  for (const source of sources) {
    const ast = parse(source);
    for (const view of ast.whole_views) for (const folded of [false, true]) {
      const data = { ...view, tree: view.flow_tree, folded: folded ? view.sections.map(s => s.id) : [] };
      const scene = model.buildScene(data);
      if (!folded) assert.equal(scene.nodes.length, view.nodes.length);
      assert.ok(scene.nodes.every(n => Number.isFinite(n.x) && Number.isFinite(n.y)));
      realEngine(scene);
      const compact = model.buildScene({ ...data, compactNodes: true });
      const significant = graph => graph.links.filter(e => e.execution && e.kind !== 'flow')
        .map(e => [e.from, e.to, e.kind, e.label].join('|')).sort();
      assert.deepEqual(significant(compact), significant(scene));
      realEngine(compact);
    }
  }
});
test('moving a node is presentation-only, uses stable offsets and does not change flow', () => {
  const data = payload(parse('a=2\nb=a+1\n'));
  const before = model.buildScene(data), n = before.nodes.find(n => n.kind === 'read');
  const after = model.buildScene({ ...data, positions: { [n.key]: [123, -56] } });
  const moved = after.nodes.find(m => m.id === n.id);
  assert.equal(moved.x, n.x + 123); assert.equal(moved.y, n.y - 56);
  assert.deepEqual(after.links, before.links);
});
test('opening a folded section reveals a member instead of retaining the old camera target', () => {
  const data=payload(parse('from decimal import Decimal, localcontext\nx=Decimal("2")\nprint(x)\n'));
  const section=data.sections.find(s=>s.line===1);
  const closed=model.buildScene({...data,folded:data.sections.map(s=>s.id)});
  assert.equal(model.focusNode(closed,section.id,1).id,section.id);
  const expanded=model.buildScene({...data,folded:data.sections.filter(s=>s.id!==section.id).map(s=>s.id)});
  const target=model.focusNode(expanded,section.id,1);
  assert.equal(target.section_id,section.id);
  assert.equal(target.line,1);
  assert.notEqual(target.id,section.id);
  const moved=model.buildScene({...data,positions:{[target.key]:[90,45]}});
  assert.equal(model.focusNode(moved,target.id,1).x,target.x+90);
});
test('source strings are text, not evaluated JavaScript; focus avoids unrelated co-inputs', () => {
  const ast = parse('text="</script><script>throw Error(1)</script>"\nx=2\nprint(text,x)\n');
  const scene = model.buildScene(payload(ast));
  assert.ok(scene.nodes.some(n => n.detail.includes('</script>')));
  realEngine(scene);
  const focused = model.connected('a', [{ from:'a',to:'sum',kind:'data' },{ from:'b',to:'sum',kind:'data' }]);
  assert.ok(focused.has('sum')); assert.ok(!focused.has('b'));
  assert.ok(model.wrap('变量'.repeat(80), 30, 3).length <= 3);
});
test('wire routes avoid node obstacles and report overlapping nodes instead of crossing them', () => {
  const boxes=[[120,-40,300,80],[350,70,500,180]];
  const route=routing.route([30,0],[600,120],boxes);
  assert.ok(route);
  assert.ok(routing.clear([[30,0], ...route, [600,120]],boxes));
  assert.equal(routing.route([30,0],[600,120],[[28,-100,160,100]]),null);
  assert.equal(routing.splineClear([30,0],[600,120],boxes), false);
});
test('compact routing clears port stubs and interior cards on long and backward wires', () => {
  const source = [-8, -38, 192, 104], obstacle = [236,-38,440,105], target = [503,22,723,150];
  const a = [174, 18], b = [521, 67];
  const path = routing.route(a, b, [source, obstacle, target], source, target);
  assert.ok(path);
  assert.ok(routing.clear(path, [source, obstacle, target]));
  assert.ok(routing.clear([a, ...path, b], [obstacle]));
  assert.ok(routing.clear([a, path[0]], [target]));
  assert.ok(routing.clear([path.at(-1), b], [source]));
  const reverse = routing.route([703, 66], [8, 30], [source, obstacle, target], target, source);
  assert.ok(reverse);
  assert.ok(routing.clear(reverse, [source, obstacle, target]));
});
test('parallel turns reserve distinct tracks around the same obstacle, including shared ports', () => {
  const left = [-8, -38, 192, 120], middle = [236, -38, 440, 121], right = [503, -38, 723, 120];
  const boxes = [left, middle, right];
  for (const backward of [false, true]) {
    const lanes = routing.laneIndex();
    const [source, target] = backward ? [right, left] : [left, right];
    const start = [backward ? 704 : 174, 20];
    for (const y of [20, 44, 68, 92]) {
      const end = [backward ? 8 : 521, y];
      const path = routing.route(start, end, boxes, source, target, lanes, [-300, -280, 1030, 420]);
      assert.ok(path?.length >= 4);
      assert.ok(routing.clear([start, ...path, end], [middle]));
      for (let i = 1; i < path.length; i++) {
        const [x, y] = path[i - 1], [nextX, nextY] = path[i];
        assert.ok(x === nextX || y === nextY, 'each segment is orthogonal');
        assert.ok(lanes.clear(path[i - 1], path[i]), 'no shared parallel tracks between port leads');
      }
      lanes.add(path);
    }
  }
  const lanes = routing.laneIndex();
  lanes.add([[10, 20], [90, 20]]);
  assert.equal(lanes.clear([50, 0], [50, 70]), true, 'a perpendicular crossing shares no segment');
  assert.equal(lanes.clear([15, 20], [60, 20]), false);
  assert.equal(lanes.clear([15, 31], [60, 31]), false);
  assert.equal(lanes.clear([15, 32], [60, 32]), true);
});
test('a long obstacle detour uses a few continuous runs instead of stair steps', () => {
  const source = [-8, 40, 160, 190], target = [775, 230, 960, 360];
  const middle = [[470, 150, 630, 330], [310, 310, 510, 460], [570, 270, 730, 350], [280, 30, 400, 210]];
  const a = [145, 130], b = [790, 280];
  const path = routing.route(a, b, [source, ...middle, target], source, target, routing.laneIndex());
  assert.ok(path);
  const wire = [a, ...path, b];
  assert.ok(routing.clear(wire, middle));
  const axes = wire.slice(1).map(([x, y], index) => {
    const [prevX, prevY] = wire[index];
    assert.ok(prevX === x || prevY === y);
    return prevX === x ? 'vertical' : 'horizontal';
  });
  const bends = axes.slice(1).filter((axis, index) => axis !== axes[index]).length;
  assert.ok(bends <= 4, `drawn with ${bends} bends`);
});
test('readable camera keeps the upper branch below the toolbar without shrinking below 85 percent', () => {
  const scene=model.buildScene(payload(parse('n=4\nif n>2:\n    x=1\nelse:\n    x=2\nprint(x)\n'),true));
  const decision=scene.nodes.find(n=>n.line===2);
  const camera=model.readableCamera(scene,decision,960,620);
  assert.ok(camera.scale>=.85 && camera.scale<=1);
  for(const n of scene.nodes) assert.ok((n.y-30+camera.offset[1])*camera.scale>=89);
});
test('loop-return wires remain separate from normal execution and can use native Comfy reroutes', () => {
  const ast=parse('x=0\nwhile x<3:\n    x+=1\nprint(x)\n');
  const scene=model.buildScene(payload(ast,true));
  const back=scene.links.find(e=>e.backward);
  assert.ok(back); assert.equal(back.type, 'LOOP'); assert.equal(back.color, model.colors.LOOP);
  assert.ok(scene.links.some(e=>e.label==='结束' && !e.backward));
  const graph=realEngine(scene), link=graph.links.values().next().value;
  const point=graph.createReroute([200,50],link);
  assert.equal(link.parentId,point.id);
  assert.equal(graph.links.size,scene.links.length);
});
test('large collection becomes item cards, each with its own compact dependency detail', () => {
  const order = i => `    {"id": "A${i}", "member": True, "budget": 300, "items": [
        {"name": "笔记本", "quantity": 3}, {"name": "钢笔", "quantity": 2}
    ]}`;
  const data = payload(parse(`orders = [
${Array.from({length: 6}, (_, i) => order(i + 1)).join(',\n')}
]
print(orders)
`));
  const overview = model.buildScene(data);
  const entries = overview.nodes.filter(n => n.collectionEntry);
  assert.equal(entries.length, 6);
  assert.equal(new Set(entries.map(node => node.x)).size, 1);
  assert.ok(overview.nodes.length < 24);
  assert.ok(overview.nodes.some(n => n.kind === 'write'));
  const entry = entries[0];
  assert.match(entry.detail, /A1/);
  assert.equal(entry.presentation.caption, '[0] 字典 · 4 项');
  assert.deepEqual(entry.collectionPreview.map(row => [row.depth, row.label]),
    [[0, '"items"'], [1, '[0]'], [1, '[1]']]);
  assert.ok(overview.links.some(e => e.from === entry.id));
  const detail = model.buildScene({...data, detailId: entry.id});
  assert.equal(detail.nodes.length, entry.detailCount);
  assert.ok(detail.nodes.some(n => n.kind === 'literal' && n.title === '常量'));
  assert.ok(detail.nodes.some(n => n.kind === 'construct'));
  const endpoints = new Map(detail.nodes.map(n => [n.id, n]));
  assert.ok(detail.links.every(e => endpoints.get(e.from).x < endpoints.get(e.to).x));
  assert.ok(detail.links.every(e => !e.connector));
  assert.ok(detail.nodes.flatMap(n => [...n.inputSlots, ...n.outputSlots])
    .every(port => !port.connector && !port.connectors));
  const moved = model.buildScene({...data, detailId: entry.id,
    positions: {[detail.nodes[0].key]: [60, 44]}});
  assert.equal(moved.nodes[0].x, detail.nodes[0].x + 60);
  assert.equal(moved.nodes[0].y, detail.nodes[0].y + 44);
  realEngine(overview);
  realEngine(detail);
});
test('nested literals remain visible when the selected line omits child dependencies', () => {
  const ast = parse(`order = {
  "note": "${'long'.repeat(120)}",
  "items": [
    {"name": "笔记本", "count": 3},
    {"name": "钢笔", "count": 2},
  ],
}
`);
  const view = ast.line_views.find(v => v.line === 1);
  const fallback = view.nodes.find(n => n.kind === 'container' && n.line === 1);
  assert.ok(!fallback.code.includes('"items"'), 'node source preview is truncated');
  for (const compactNodes of [false, true]) {
    const scene = model.buildScene({ ...view, collections: ast.collections, compactNodes });
    const root = scene.nodes.find(n => n.id === fallback.id);
    assert.equal(root.presentation.caption, '字典 · 2 项');
    assert.deepEqual(root.collectionPreview.map(({label, depth, value}) => [label, depth, value]), [
      ['"items"', 0, '列表 · 2 项'], ['[0]', 1, '字典 · 2 项'], ['[1]', 1, '字典 · 2 项']
    ]);
    const items = ast.collections[ast.collections[root.collectionId].rows[1].collection];
    assert.equal(ast.collections[items.rows[1].collection].rows[0].code, '"钢笔"');
    realEngine(scene);
  }
});
test('a nested dictionary keeps sibling inputs next to their consumers and faces forward', () => {
  const ast = parse('inventory = {\n  "笔记本": {"price": 20, "stock": 12},\n}\n');
  const view = ast.line_views.find(v => v.line === 2);
  const scene = model.buildScene({ ...view, collections: ast.collections, compactNodes: true });
  const outer = scene.nodes.find(n => n.entry_key === '"笔记本"');
  const incoming = scene.links.filter(e => e.to === outer.id);
  const states = new Map(scene.nodes.map(n => [n.id, n]));
  assert.equal(incoming.length, 2);
  const [key, value] = incoming.map(e => states.get(e.from));
  assert.equal(key.kind, 'literal');
  assert.equal(value.kind, 'container');
  assert.equal(key.x, value.x);
  assert.ok(key.y < value.y);
  assert.ok(scene.links.every(e => states.get(e.from).x < states.get(e.to).x));
  const camera = model.readableCamera(scene, outer, 936, 650);
  assert.ok((outer.x + outer.width + camera.offset[0]) * camera.scale <= 936);
  assert.ok(scene.nodes.every(node => (node.x + camera.offset[0]) * camera.scale >= 0));
  realEngine(scene);
});
test('world coordinates are independent of viewport size and final results stay beside their writers', () => {
  const ast = parse('result = (left + right) * (high - low) + adjustment\n');
  for (const view of [ast.line_views[0], payload(ast)]) {
    const build = layoutWidth => model.buildScene({ ...view, compactNodes: true, layoutWidth });
    const wide = build(1600), narrow = build(490);
    assert.deepEqual(narrow, wide);
    assert.ok(Math.max(...narrow.nodes.map(n => n.x + n.width)) > 490);
    const byId = new Map(narrow.nodes.map(n => [n.id, n]));
    const adjustment = narrow.nodes.find(n => n.symbol === 'adjustment');
    const consumer = narrow.links.find(e => e.from === adjustment.id);
    const multiply = narrow.nodes.find(n => n.operator === 'Mult');
    assert.equal(adjustment.x, multiply.x);
    assert.ok(adjustment.x < byId.get(consumer.to).x);
    const binding = narrow.links.find(e => e.kind === 'binding');
    const writer = byId.get(binding.from), result = byId.get(binding.to);
    assert.ok(result.x > writer.x + writer.width);
    assert.equal(writer.y + 24 * binding.output, result.y + 24 * binding.input);
    realEngine(narrow);
  }
});
test('layout allocates a larger routing corridor to a denser set of connections', () => {
  const gap = count => {
    const args = Array.from({ length: count }, (_, i) => i + 1).join(', ');
    const ast = parse(`result = combine(${args})\n`);
    const scene = model.buildScene({ ...ast.line_views[0], compactNodes: true });
    const consumer = scene.nodes.find(n => n.kind === 'call');
    const inputs = scene.links.filter(e => e.to === consumer.id).map(e => scene.nodes.find(n => n.id === e.from));
    assert.ok(inputs.length >= count);
    assert.ok(inputs.every(n => n.x < consumer.x));
    return consumer.x - Math.max(...inputs.map(n => n.x + n.width));
  };
  assert.ok(gap(9) > gap(2));
});

test('portrait overview stacks folded sections while preserving graph connections', () => {
  const source = fs.readFileSync(path.join(root, 'examples/逐行运算.py'), 'utf8');
  const data = payload(parse(source), true);
  const landscape = model.buildScene(data);
  const portrait = model.buildScene({ ...data, portraitLayout: true });
  assert.deepEqual(portrait.links, landscape.links);
  assert.ok(new Set(portrait.nodes.map(n => n.base[1])).size >
      new Set(landscape.nodes.map(n => n.base[1])).size);
});
