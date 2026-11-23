/* The Python AST is authoritative. This adapter only builds a display graph. */
(function (root) {
  'use strict';
  const kinds = {
    literal: '常量', reference: '变量引用', read: '读取', write: '赋值',
    symbol: '变量', variable: '合并变量值', operator: '运算', condition: '判断',
    truth: '真值判断', branch: '选择路径', call: '调用函数', argument: '传入参数',
    receive: '接收返回值', return: '返回', parameter: '参数', entry: '函数入口',
    value: '结果', construct: '创建', container: '容器', lookup: '访问',
    element: '元素', definition: '定义', import: '导入', comment: '说明',
    try: '异常保护', exception: '异常处理', raise: '抛出异常', finally: '清理',
    context_enter: '进入上下文', context_exit: '退出上下文', join: '路径汇合',
    control: '流程跳转', pending_return: '待返回值', format: '格式化',
    unbound: '尚未定义', unsupported: '暂未细分'
  };
  const colors = {
    EXEC: '#f6f6f7', LOOP: '#e4c790', EXCEPTION: '#efa496',
    bool: '#c26370', int: '#6fcbaf', float: '#c1db7f', str: '#df86c9',
    complex: '#de9e76', bytes: '#6199ad', NoneType: '#b2a8a3',
    dict: '#69a7e1', dict_entry: '#a5d9ee', list: '#8e9adf',
    tuple: '#b19bda', set: '#e5cc83', function: '#af82b5',
    DATA: '#a8adb4'
  };
  const typeNames = {
    EXEC: '执行顺序', LOOP: '循环返回', EXCEPTION: '异常路径',
    bool: '布尔值', int: '整数', float: '浮点数', str: '字符串',
    complex: '复数', bytes: '字节串', NoneType: 'None',
    dict: '字典', dict_entry: '字典条目', list: '列表', tuple: '元组',
    set: '集合', function: '函数', DATA: '类型待定'
  };
  const flowKinds = new Set(['flow', 'guard', 'exception', 'section']);
  const key = n => n.layout_key || `${n.scope}:${n.line}:${n.kind}:${n.code}:${n.id}`;
  const execLabel = edge => edge.kind === 'exception' ? (edge.label || '异常')
    : ({ '结束': '退出', '下一轮': '返回判断' }[edge.label]
      || edge.label || '执行');
  function wrap(text, count = 30, maxLines = 4) {
    const chars = Array.from(String(text || ''));
    const lines = []; let line = '', width = 0;
    for (const ch of chars) {
      const size = ch.charCodeAt(0) > 255 ? 2 : 1;
      if (ch === '\n' || width + size > count) {
        lines.push(line); line = ''; width = 0;
        if (lines.length >= maxLines) { lines[maxLines - 1] += '…'; return lines; }
      }
      if (ch !== '\n') { line += ch; width += size; }
    }
    if (line) lines.push(line);
    return lines;
  }
  function connected(selected, edges) {
    if (!selected) return new Set();
    const result = new Set([selected]);
    for (const direction of ['from', 'to']) {
      const adjacency = new Map();
      for (const e of edges) {
        if (!['data', 'binding', 'reference'].includes(e.kind)) continue;
        const a = e[direction], b = e[direction === 'from' ? 'to' : 'from'];
        if (!adjacency.has(a)) adjacency.set(a, []);
        adjacency.get(a).push(b);
      }
      const seen = new Set([selected]), queue = [selected];
      while (queue.length) for (const id of adjacency.get(queue.pop()) || []) {
        result.add(id); if (!seen.has(id)) { seen.add(id); queue.push(id); }
      }
    }
    return result;
  }
  const isData = e => e.kind === 'data' || e.kind === 'binding';
  const sourceOrder = (a, b) => a.line - b.line || a.order - b.order;
  const summaryPreview = code => String(code || '').replace(/\s*\n\s*/g, ' ').trim();
  const readableScaleFloor = .76;

  const collectionLabel = shape => `${shape.type} · ${shape.rows.length} 项`;
  function collectionPreview(shapes, id) {
    const preview = [];
    function visit(shape, depth) {
      const branches = shape.rows.filter(row => shapes[row.collection]);
      const visible = branches.length ? branches : depth === 0 ? shape.rows : [];
      for (const row of visible) {
        if (preview.length >= 6) return;
        const nested = shapes[row.collection];
        preview.push({ label: summaryPreview(row.label), depth, nested: Boolean(nested),
          value: nested ? collectionLabel(nested) : summaryPreview(row.code) });
        if (nested && depth < 3) visit(nested, depth + 1);
      }
    }
    visit(shapes[id], 0);
    return preview;
  }

  // Summarize each value feeding the largest literal collection in a block.
  // If a node has a second consumer, it stays visible outside the summary.
  function collectionEntries(nodes, edges) {
    if (nodes.length < 36) return [];
    const byId = new Map(nodes.map(n => [n.id, n]));
    const incoming = new Map(), outgoing = new Map();
    for (const e of edges) {
      if (!byId.has(e.from)) continue;
      if (!outgoing.has(e.from)) outgoing.set(e.from, []);
      outgoing.get(e.from).push(e);
      if (isData(e) && byId.has(e.to)) {
        if (!incoming.has(e.to)) incoming.set(e.to, []);
        incoming.get(e.to).push(e);
      }
    }
    const entries = [];
    for (const n of nodes.slice().reverse()) {
      if (n.kind !== 'construct') continue;
      const inputs = incoming.get(n.id) || [];
      if (inputs.length < 3 || inputs.some(e => byId.get(e.from).kind !== 'element')) continue;
      for (const edge of inputs) {
        const root = byId.get(edge.from), members = new Set([root.id]);
        function gather(id) {
          for (const e of incoming.get(id) || []) {
            if (members.has(e.from) || outgoing.get(e.from).some(link => link.to !== id)) continue;
            members.add(e.from);
            gather(e.from);
          }
        }
        gather(root.id);
        if (members.size >= 5) entries.push({ root, members });
      }
      if (entries.length >= 2 && entries.reduce((sum, e) => sum + e.members.size, 0) >= nodes.length / 2) {
        return entries;
      }
      entries.length = 0;
    }
    return entries;
  }

  function layoutAtoms(nodes, links, compact) {
    if (!nodes.length) return [0, 0];
    const byId = new Map(nodes.map(n => [n.id, n]));
    const incoming = new Map(), outgoing = new Map(), parents = new Map();
    const depth = new Map(nodes.map(n => [n.id, 0]));
    const flowNodes = new Set();
    for (const e of links) {
      if (!isData(e)) {
        flowNodes.add(e.from);
        flowNodes.add(e.to);
        continue;
      }
      if (!byId.has(e.from) || !byId.has(e.to) || e.from === e.to) continue;
      if (!outgoing.has(e.from)) outgoing.set(e.from, []);
      outgoing.get(e.from).push(e);
      if (!parents.has(e.to)) parents.set(e.to, []);
      parents.get(e.to).push(e);
      incoming.set(e.to, (incoming.get(e.to) || 0) + 1);
    }
    // Cyclic state references are not a layout constraint. Kahn's traversal
    // leaves any cycle members in their existing rank without dropping links.
    const ready = nodes.filter(n => !incoming.has(n.id)).map(n => n.id);
    for (let i = 0; i < ready.length; i++) {
      const id = ready[i];
      for (const { to: next } of outgoing.get(id) || []) {
        depth.set(next, Math.max(depth.get(next), depth.get(id) + 1));
        incoming.set(next, incoming.get(next) - 1);
        if (!incoming.get(next)) ready.push(next);
      }
    }
    // Place independent inputs next to their first consumer. A literal key
    // for an outer dictionary then lines up with its nested dictionary value.
    const ranked = new Set(ready);
    for (const id of ready) {
      const consumers = outgoing.get(id);
      if (parents.has(id) || flowNodes.has(id) || !consumers?.length) continue;
      const firstUse = Math.min(...consumers.map(e => ranked.has(e.to) ? depth.get(e.to) : 0));
      depth.set(id, Math.max(0, firstUse - 1));
    }
    const columns = new Map();
    for (const n of nodes.slice().sort(sourceOrder)) {
      const rank = depth.get(n.id);
      if (!columns.has(rank)) columns.set(rank, []);
      columns.get(rank).push(n);
    }
    const sorted = [...columns].sort(([a], [b]) => a - b);
    const order = new Map();
    const updateOrder = column => column.forEach((node, index) =>
      order.set(node.id, (index + .5) / column.length));
    for (const [, column] of sorted) updateOrder(column);
    // Sweep neighboring columns so inputs are arranged near their consumers.
    function sweep(ordered, neighbors, next, port, step) {
      for (const [rank, column] of ordered) {
        const scores = new Map(column.map(n => {
          const adjacent = (neighbors.get(n.id) || []).filter(e => depth.get(e[next]) === rank + step);
          const mean = adjacent.reduce((sum, e) => sum + order.get(e[next]) + e[port] / 10000, 0) / adjacent.length;
          return [n.id, adjacent.length ? mean : order.get(n.id)];
        }));
        column.sort((a, b) => scores.get(a.id) - scores.get(b.id));
        updateOrder(column);
      }
    }
    sweep(sorted.slice().reverse(), outgoing, 'to', 'input', 1);
    sweep(sorted, parents, 'from', 'output', -1);
    const slotY = index => 12 + index * 24;
    const gapY = compact ? 50 : 54;
    const columnWidths = sorted.map(([, column]) => Math.max(...column.map(n => n.width)));
    // A difference array counts the wires crossing each column boundary,
    // including dependencies that skip ranks.
    const columnIndex = new Map(sorted.map(([rank], index) => [rank, index]));
    const demand = new Array(sorted.length).fill(0);
    for (const edge of links) {
      const from = columnIndex.get(depth.get(edge.from));
      const to = columnIndex.get(depth.get(edge.to));
      if (from === undefined || to === undefined || from === to) continue;
      demand[Math.min(from, to)]++;
      demand[Math.max(from, to)]--;
    }
    let crossing = 0;
    const gaps = demand.map(delta => {
      crossing += delta;
      return (compact ? 44 : 68) + Math.min(42, Math.max(0, crossing - 3) * 6);
    });
    // World coordinates follow the dependency ranks. The viewport only moves
    // the camera, so resizing it never turns a forward connection into a return wire.
    const ordered = sorted.map(([, column]) => column);
    let width = 0;
    for (const [index, column] of ordered.entries()) {
      for (const n of column) n.x = width;
      width += columnWidths[index] + (index < ordered.length - 1 ? gaps[index] : 0);
    }
    function align(columns, neighbors, next, theirPort, ourPort, direction) {
      for (const column of columns) {
        let y = 0;
        for (const n of column) {
          const joined = (neighbors.get(n.id) || []).filter(e => (byId.get(e[next]).x - n.x) * direction > 0);
          const desired = joined.length ? joined.reduce((sum, e) =>
            sum + byId.get(e[next]).y + slotY(e[theirPort]) - slotY(e[ourPort]), 0) / joined.length : n.y;
          n.y = Math.max(y, desired);
          y = n.y + n.height + gapY;
        }
      }
    }
    align(ordered, parents, 'from', 'output', 'input', -1);
    align(ordered.slice().reverse(), outgoing, 'to', 'input', 'output', 1);
    const top = Math.min(...nodes.map(n => n.y));
    for (const n of nodes) n.y -= top;
    return [width, Math.max(...nodes.map(n => n.y + n.height))];
  }

  const relayKinds = new Set(['value', 'argument', 'receive']);
  function compactGraph(nodes, edges, protectedIds) {
    const byId = new Map(nodes.map(node => [node.id, { ...node }]));
    const entering = new Map(nodes.map(node => [node.id, new Set()]));
    const leaving = new Map(nodes.map(node => [node.id, new Set()]));
    const redirects = new Map();
    const live = new Set();
    function add(edge) {
      live.add(edge);
      entering.get(edge.to).add(edge);
      leaving.get(edge.from).add(edge);
    }
    function remove(edge) {
      live.delete(edge);
      entering.get(edge.to).delete(edge);
      leaving.get(edge.from).delete(edge);
    }
    for (const edge of edges) {
      if (byId.has(edge.from) && byId.has(edge.to)) add(edge);
    }
    for (const node of byId.values()) {
      if (protectedIds.has(node.id)) continue;
      const inputs = [...entering.get(node.id)], outputs = [...leaving.get(node.id)];
      const source = inputs.length === 1 && isData(inputs[0])
        ? byId.get(inputs[0].from) : null;
      // A pass-through value may own the next statement's ordinary sequence
      // edge. Short-circuit, exception and return edges keep their endpoints.
      if (relayKinds.has(node.kind) && source && source.id !== node.id && source.statement_id === node.statement_id
          && source.section_id === node.section_id
          && outputs.every(e => e.to !== source.id && (isData(e) || e.kind === 'flow'))) {
        remove(inputs[0]);
        for (const edge of outputs) {
          remove(edge);
          add({ ...edge, from: source.id });
        }
        if (node.kind === 'value' || node.kind === 'receive') {
          source.resultLabel = node.kind === 'receive' ? '返回值' : (source.resultLabel || node.title);
        }
        redirects.set(node.id, source.id);
        continue;
      }
      if (node.kind === 'reference' || node.kind === 'symbol' &&
          (node.context || node.role === '外部或尚未赋值的变量')) {
        if (inputs.length || outputs.length !== 1 || !isData(outputs[0])) continue;
        const consumer = byId.get(outputs[0].to);
        if (consumer.kind !== 'read' || consumer.symbol !== node.symbol) continue;
        consumer.origin_line = node.origin_line || node.assignment_line || consumer.origin_line;
        consumer.reference_label = node.reference_label;
        remove(outputs[0]);
        redirects.set(node.id, consumer.id);
      }
    }
    return { nodes: [...byId.values()].filter(n => !redirects.has(n.id)),
      edges: [...live], redirects };
  }

  const operatorNames = {
    Add: '加法', Sub: '减法', Mult: '乘法', Div: '除法', FloorDiv: '整除',
    Mod: '取余', Pow: '乘方', MatMult: '矩阵乘法',
    Eq: '等于', NotEq: '不等于', Lt: '小于', LtE: '小于等于',
    Gt: '大于', GtE: '大于等于', And: '逻辑与', Or: '逻辑或',
    Not: '逻辑非', UAdd: '取正', USub: '取负', Invert: '按位取反',
    In: '包含判断', NotIn: '不包含判断', Is: '同一对象', IsNot: '不同对象',
    BitAnd: '按位与', BitOr: '按位或', BitXor: '按位异或',
    LShift: '左移', RShift: '右移'
  };
  const literalNames = { int: '整数', float: '小数', str: '字符串',
    bool: '布尔值', NoneType: '空值', bytes: '字节', complex: '复数' };
  const palettes = {
    data: { header: '#2c4249', body: '#222c33', accent: '#8ed5e7' },
    binding: { header: '#304638', body: '#252f29', accent: '#9cddb1' },
    calculation: { header: '#30425c', body: '#242e3e', accent: '#a6c9fc' },
    flow: { header: '#4a3e2c', body: '#332c22', accent: '#ebc381' },
    function: { header: '#433754', body: '#302839', accent: '#d2b5ec' },
    neutral: { header: '#343a45', body: '#272c34', accent: '#c0c9d8' }
  };

  function presentation(node) {
    const kind = node.kind, detail = node.detail || '';
    const source = summaryPreview(node.preview || node.code);
    let caption = detail || node.title;
    let category = kinds[kind] || '代码';
    let body = '', mono = false, palette = palettes.neutral, width = 184;
    if (kind === 'section') {
      return { caption: node.title, category: '代码块',
        body: detail, mono: true, palette, width: 292 };
    }
    if (node.collectionPreview) {
      return { caption: node.collectionEntry ? `${node.entry_key || `[${node.index}]`} ${node.collectionLabel}`
        : node.collectionLabel, category: node.collectionEntry ? '集合元素' : '容器',
        body: '', mono: true, palette: palettes.data, width: 238 };
    }
    if (node.collectionEntry) {
      return { caption: node.entry_key || node.title, category: '集合元素',
        body: detail, mono: true, palette, width: 226 };
    }
    if (kind === 'literal') {
      category = literalNames[node.literal_type] || (node.role === '属性名' ? '属性名' : '常量');
      palette = palettes.data;
      width = node.literal_type === 'str' ? 184 : 136;
    } else if (['symbol', 'variable', 'read', 'write', 'reference'].includes(kind)) {
      const label = node.symbol || detail;
      palette = palettes.binding;
      if (kind === 'read') {
        caption = node.symbol ? `读取 ${label}` : detail === '取值' ? '读取内容' : detail;
        if (!node.symbol) {
          const input = node.inputs?.[0];
          if (input === '属性位置') caption = '读取属性';
          if (input === '元素位置') caption = '读取元素';
          body = source;
        }
      }
      if (kind === 'write') caption = `写入 ${label}`;
      if (kind === 'symbol' || kind === 'reference') caption = label;
      if (kind === 'variable') {
        caption = label;
        body = detail === label ? '' : detail;
      }
    } else if (['operator', 'lookup', 'format', 'construct'].includes(kind)) {
      palette = palettes.calculation;
      if (kind === 'operator' && operatorNames[node.operator]) {
        caption = `${operatorNames[node.operator]} ${detail}`;
      }
      if (kind !== 'construct' || source.length <= 52) body = source;
      if (kind === 'construct') {
        const count = (node.inputs || []).length;
        if (!body || body === caption) body = `${count} 个输入`;
      }
      mono = kind !== 'construct' || body === source;
      width = 204;
    } else if (['condition', 'truth', 'branch', 'join', 'control', 'try',
      'exception', 'raise', 'finally', 'context_enter', 'context_exit'].includes(kind)) {
      palette = palettes.flow;
      if (kind === 'condition') {
        if (detail === '条件选路') caption = '按条件选择路径';
        body = node.preview ? source : (source.endsWith(':') ? '' : source);
        mono = true;
      }
      if (kind === 'truth') body = '将输入判断为真或假';
      width = 204;
    } else if (['call', 'receive', 'argument', 'parameter', 'return', 'entry',
      'definition', 'pending_return'].includes(kind)) {
      palette = palettes.function;
      if (kind === 'call') {
        caption = `调用 ${node.function || '函数'}`;
        body = source;
        mono = true;
        width = 226;
      }
      if (kind === 'parameter' && node.symbol) caption = node.symbol;
      if (kind === 'receive' && node.function) caption = `${node.function} 的返回值`;
      if (kind === 'definition' && node.function && !detail.includes(node.function)) caption = `${detail} ${node.function}`;
      if (kind === 'return' || kind === 'pending_return') {
        body = source;
        mono = true;
      }
    } else if (kind === 'element' || kind === 'container' || kind === 'value') {
      palette = palettes.data;
      if (kind === 'element') {
        caption = node.spread ? '展开字典' : node.entry_key || `[${node.index ?? 0}]`;
        category = node.entry_key ? '字典键' : node.spread ? '字典展开' : '集合下标';
        body = node.collectionLabel || source;
        mono = true;
      }
      if (kind === 'container') body = source;
    } else if (kind === 'unsupported') {
      caption = source || '当前语法';
      body = '';
      width = 226;
    }
    if (body === caption) body = '';
    return { caption, category, body, mono, palette, width };
  }

  function buildScene(payload) {
    let nodes = payload.nodes || [], sections = payload.sections || [];
    const closed = new Set(payload.folded || []), raw = new Map(nodes.map(n => [n.id, n]));
    let edges = (payload.edges || []).filter(e => e.kind !== 'call' && e.kind !== 'reference');
    const specs = [], links = [], groups = [];
    const shapes = payload.collections || {};
    const members = new Map(), summaries = new Map();
    for (const n of nodes) {
      if (!members.has(n.section_id)) members.set(n.section_id, []);
      members.get(n.section_id).push(n);
    }
    for (const s of sections) {
      if (s.subflow_group || closed.has(s.id) && !payload.detailId) continue;
      for (const entry of collectionEntries(members.get(s.id) || [], edges)) {
        summaries.set(entry.root.id, entry);
      }
    }
    const detail = summaries.get(payload.detailId);
    if (detail) {
      nodes = nodes.filter(n => detail.members.has(n.id));
      sections = [];
    } else {
      const hidden = new Set();
      for (const entry of summaries.values()) {
        for (const id of entry.members) if (id !== entry.root.id) hidden.add(id);
      }
      nodes = nodes.filter(n => !hidden.has(n.id));
    }
    let redirects = new Map();
    if (payload.compactNodes) {
      const retained = new Set(summaries.keys());
      for (const edge of payload.section_links || []) {
        if (edge.kind !== 'flow') {
          retained.add(edge.from_node);
          retained.add(edge.to_node);
        }
      }
      ({ nodes, edges, redirects } = compactGraph(nodes, edges, retained));
    }
    function projected(id) {
      while (redirects.has(id)) id = redirects.get(id);
      return id;
    }
    const allSections = new Map(sections.map(s => [s.id, s]));
    for (const s of sections) {
      if (closed.has(s.id) || s.subflow_group) {
        specs.push({ id: s.id, key: `section:${s.line}:${s.title}`, section: s,
          line: s.line, end_line: s.end_line, kind: 'section', title: s.title,
          detail: s.code || s.teaching?.code || '', width: 292, order: 0,
          inputSlots: [], outputSlots: [], x: 0, y: 0 });
      }
    }
    for (const [order, n] of nodes.entries()) {
      if (closed.has(n.section_id) && !detail || allSections.get(n.section_id)?.subflow_group) continue;
      const entry = detail ? null : summaries.get(n.id);
      const collectionId = n.kind === 'container' ? n.id : n.collection_id;
      const shape = shapes[collectionId];
      specs.push({ ...n, order, key: entry ? `entry:${key(n)}` : key(n),
        detail: entry ? summaryPreview(n.code) : n.title, title: entry ? n.title : kinds[n.kind] || n.kind,
        width: entry ? 228 : 226, inputSlots: [], outputSlots: [], x: 0, y: 0,
        ...(entry ? { collectionEntry: true, detailCount: entry.members.size } : {}),
        ...(shape ? { collectionId, collectionLabel: collectionLabel(shape),
          collectionPreview: n.kind === 'container' || entry ? collectionPreview(shapes, collectionId) : null } : {}) });
    }
    const lookup = new Map(specs.map(n => [n.id, n]));
    for (const edge of edges) if (lookup.has(edge.from) && lookup.has(edge.to)) links.push({ ...edge });
    for (const edge of payload.section_links || []) {
      const from = lookup.has(edge.source) ? edge.source : projected(edge.from_node);
      const to = lookup.has(edge.target) ? edge.target : projected(edge.to_node);
      if (from && to && from !== to && lookup.has(from) && lookup.has(to))
        links.push({ ...edge, from, to });
    }
    // Put the control ports on the first rows, consistently on both sides.
    links.sort((a, b) => Number(flowKinds.has(b.kind)) - Number(flowKinds.has(a.kind))
      || (a.port ?? 0) - (b.port ?? 0));
    const seen = new Set(), filtered = [];
    for (const e of links) {
      const identity = `${e.from}:${e.to}:${e.kind}:${e.label}:${e.port}`;
      if (seen.has(identity)) continue; seen.add(identity);
      const from = lookup.get(e.from), to = lookup.get(e.to);
      const execution = flowKinds.has(e.kind);
      const backward = execution && e.kind !== 'exception' && to.line < from.line;
      const valueType = from.value_type || from.literal_type;
      const type = e.kind === 'exception' ? 'EXCEPTION' : backward ? 'LOOP' : execution ? 'EXEC'
        : Object.hasOwn(colors, valueType) ? valueType : 'DATA';
      const color = colors[type];
      const localLabel = (to.inputs || [])[e.port];
      const label = execution ? execLabel(e) : localLabel || e.label || '数据';
      const outputKey = `${type}:${execution ? label : ''}`;
      let output = from.outputSlots.findIndex(s => s.key === outputKey);
      if (output < 0) {
        output = from.outputSlots.length;
        from.outputSlots.push({ key: outputKey, type, color,
          label: execution ? label : type === 'dict_entry' ? '键值对' : from.resultLabel?.includes('返回') || from.kind === 'call'
            ? '返回值' : from.kind === 'operator' || from.kind === 'condition' ? '结果' : '值',
          execution });
      }
      // Every real incoming edge receives its own input. A merge must not discard predecessors.
      const input = to.inputSlots.length;
      to.inputSlots.push({ type, label, execution, color });
      filtered.push({ ...e, type, execution, output, input, backward, color });
    }
    for (const n of specs) {
      n.presentation = presentation(n);
      if (payload.compactNodes) n.width = n.presentation.width;
      const slots = Math.max(n.inputSlots.length, n.outputSlots.length);
      const hasWidget = n.kind === 'section' || n.collectionEntry || n.collectionPreview?.length;
      n.previewLines = n.presentation.body ? (hasWidget || n.presentation.body.length > 18 ? 2 : 1) : 0;
      const rows = n.collectionPreview?.length || n.previewLines;
      n.height = Math.max(hasWidget ? 126 : 50,
        slots * 24 + 32 + (hasWidget ? 38 : 0) + (rows ? rows * 19 + 12 : 0));
    }
    const dimensions = new Map(), perSection = new Map();
    for (const n of specs) {
      const id = n.section_id ?? n.id;
      if (!perSection.has(id)) perSection.set(id, []);
      perSection.get(id).push(n);
    }
    for (const s of sections) {
      const part = perSection.get(s.id) || [];
      const closedNode = part.find(n => n.id === s.id);
      if (closedNode) {
        dimensions.set(s.id, [closedNode.width, closedNode.height]);
      } else if (part.length) {
        const [width, height] = layoutAtoms(part, filtered, payload.compactNodes);
        dimensions.set(s.id, [width + 64, height + 80]);
        groups.push({ id: s.id, title: `L${s.line}${s.end_line > s.line ? '–' + s.end_line : ''}  ${s.title}` });
      }
    }
    const vertical = payload.portraitLayout || sections.length > 10;
    function place(tree) {
      if (tree?.kind === 'section') {
        const size = dimensions.get(tree.id);
        return size ? { width: size[0], height: size[1], positions: [[tree.id, 0, 0]] } : null;
      }
      const parts = (tree?.children || []).map(place).filter(Boolean);
      if (!parts.length) return null;
      const fork = tree.kind === 'fork', across = fork === vertical;
      const gap = across ? 112 : 78;
      const sum = axis => parts.reduce((total, p) => total + p[axis], 0) + (parts.length - 1) * gap;
      const width = across ? sum('width') : Math.max(...parts.map(p => p.width));
      const height = across ? Math.max(...parts.map(p => p.height)) : sum('height');
      let cursor = 0;
      const positions = [];
      for (const part of parts) {
        const dx = across ? cursor : 0;
        const dy = across ? (vertical ? 0 : (height - part.height) / 2) : cursor;
        for (const [id, x, y] of part.positions) positions.push([id, x + dx, y + dy]);
        cursor += (across ? part.width : part.height) + gap;
      }
      return { width, height, positions };
    }
    if (sections.length) {
      const tree = payload.tree || { kind: 'sequence', children: sections.map(s => ({ kind: 'section', id: s.id })) };
      for (const [id, x, y] of place(tree)?.positions || []) {
        for (const n of perSection.get(id) || []) {
          const pad = n.kind === 'section' ? 0 : 32;
          n.x += x + pad; n.y += y + pad;
        }
      }
    } else {
      layoutAtoms(specs, filtered, payload.compactNodes);
    }
    for (const n of specs) {
      n.base = [n.x, n.y];
      const saved = payload.positions?.[n.key];
      if (saved) { n.x += saved[0]; n.y += saved[1]; }
    }
    return { nodes: specs, links: filtered, groups, sections: allSections,
      detail: detail ? detail.root : null, redirects };
  }
  function focusNode(scene, id, line) {
    while (scene.redirects?.has(id)) id = scene.redirects.get(id);
    const exact = scene.nodes.find(n => n.id === id);
    if (exact) return exact;
    const members = scene.nodes.filter(n => n.section_id === id);
    if (members.length) return members.find(n => n.line === line) || members[0];
    const matchingLine = scene.nodes.find(n => n.line === line)
      || scene.nodes.find(n => (n.collectionEntry || n.kind === 'section')
        && n.line <= line && n.end_line >= line);
    if (matchingLine) return matchingLine;
    return scene.nodes.reduce((nearest, node) => {
      if (!nearest || Math.abs(node.line - (line ?? 0)) < Math.abs(nearest.line - (line ?? 0))) return node;
      return nearest;
    }, null);
  }
  function readableCamera(scene, node, width, height) {
    const compact = scene.nodes.length <= 12 && scene.nodes.every(n => n.kind === 'section');
    const singleStatement = scene.nodes.length > 0 &&
      scene.nodes[0].statement_id && scene.nodes.every(n => n.statement_id === scene.nodes[0].statement_id);
    const top = Math.min(...scene.nodes.map(n => n.y - 30));
    const bottom = Math.max(...scene.nodes.map(n => n.y + n.height));
    if (singleStatement) {
      const left = Math.min(...scene.nodes.map(n => n.x));
      const right = Math.max(...scene.nodes.map(n => n.x + n.width));
      const scale = Math.max(readableScaleFloor, Math.min(1,
        (width - 56) / (right - left), (height - 135) / (bottom - top)));
      if ((right - left) * scale <= width - 26 && (bottom - top) * scale <= height - 115) {
        return { scale, offset: [28 / scale - left, 96 / scale - top] };
      }
    }
    const scale = compact ? Math.max(.85, Math.min(1, (height - 150) / (bottom - top))) : 1;
    return { scale, offset: node ? [80 / scale - node.x,
      compact ? Math.max(130 / scale - node.y, 90 / scale - top) : 130 - node.y] : [60,100] };
  }
  const api = { buildScene, focusNode, readableCamera, connected, wrap, kinds, colors, typeNames };
  if (typeof module !== 'undefined') module.exports = api;
  root.PyvisModel = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
