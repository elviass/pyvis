"""Pure AST -> fine-grained code graph. Source is parsed, never executed/imported."""
from __future__ import annotations
import ast
import json
import sys
from .blueprint_sections import whole_views
from .blueprint_reading import reading_flow
from .blueprint_teaching import lesson
from .blueprint_control import ControlFlow
from .blueprint_liveness import read_before_write, needed_after, names
from .blueprint_types import annotate_value_types

OPS = {'Add': '+', 'Sub': '−', 'Mult': '×', 'Div': '÷', 'FloorDiv': '//',
       'Mod': '%', 'Pow': '**', 'Eq': '==', 'NotEq': '≠', 'Lt': '<', 'LtE': '≤',
       'Gt': '>', 'GtE': '≥', 'And': 'and', 'Or': 'or', 'Not': 'not',
       'USub': '−', 'UAdd': '+', 'In': 'in', 'NotIn': 'not in', 'Is': 'is',
       'IsNot': 'is not', 'BitAnd': '&', 'BitOr': '|', 'BitXor': '^',
       'MatMult': '@', 'Invert': '~', 'LShift': '<<', 'RShift': '>>'}


class StoredNames(ast.NodeVisitor):
    def __init__(self): self.names = set()
    def visit_Name(self, node):
        if isinstance(node.ctx, ast.Store): self.names.add(node.id)
    def visit_FunctionDef(self, node): pass
    def visit_AsyncFunctionDef(self, node): pass
    def visit_ClassDef(self, node): pass
    def visit_Lambda(self, node): pass


class GraphBuilder(ControlFlow):
    def __init__(self, source):
        self.source = source
        self.nodes = []
        self.edges = []
        self.scopes = [{'id': 'main', 'name': '主程序'}]
        self.scope = 'main'
        self.definitions = {}
        self.calls = []
        self.warnings = []
        self.loops = []
        self.bindings = {}
        self.external_symbols = {}
        self.call_results = {}
        self.collections = {}
        self.scope_bodies = {}
        self.statement = None
        self.exception_target = None
        self.cleanups = []

    def text(self, node):
        return (ast.get_source_segment(self.source, node) or '')[:400]

    def node(self, source, kind, title, inputs=(), **extra):
        if len(self.nodes) >= 4000:
            raise ValueError('代码图超过 4000 个节点，请按文件拆分代码')
        n = {'id': f'n{len(self.nodes)}', 'kind': kind, 'title': title,
             'code': self.text(source), 'line': getattr(source, 'lineno', 1),
             'end_line': getattr(source, 'end_lineno', 1), 'scope': self.scope,
             'inputs': list(inputs),
             'statement_id': f'{self.scope}:{self.statement.lineno}:{self.statement.col_offset}:{type(self.statement).__name__}' if self.statement else '',
             **extra}
        self.nodes.append(n)
        if (self.exception_target and not extra.get('no_exception_edge') and kind in
                ('read', 'operator', 'call', 'lookup', 'write', 'construct', 'truth',
                 'format', 'context_enter', 'context_exit', 'raise', 'import')):
            self.edge(n['id'], self.exception_target, 'exception', '可能发生异常')
        return n['id']

    def edge(self, source, target, kind='data', label='', port=0):
        if source is not None and target is not None:
            self.edges.append({'from': source, 'to': target, 'kind': kind,
                               'label': label, 'port': port})

    def flow(self, tails, target):
        for source, label in tails:
            self.edge(source, target, 'flow', label)

    def result_value(self, source, operation, title='结果'):
        result = self.node(source, 'value', title, ['来源'], operation=operation)
        self.edge(operation, result)
        return result

    def symbol(self, source, name):
        key = (self.scope, name)
        if name in self.bindings:
            return self.bindings[name]
        if key not in self.external_symbols:
            self.external_symbols[key] = self.node(source, 'symbol', name,
                symbol=name, role='外部或尚未赋值的变量')
        return self.external_symbols[key]

    def expression(self, node):
        if node is None:
            return None
        if isinstance(node, ast.Name):
            variable = self.symbol(node, node.id)
            operation = self.node(node, 'read', '取值', ['变量'], symbol=node.id)
            self.edge(variable, operation, 'binding', node.id)
            return self.result_value(node, operation, f'{node.id} 的值')
        if isinstance(node, ast.Constant):
            text = repr(node.value)
            return self.node(node, 'literal', text[:80], literal_type=type(node.value).__name__)
        if isinstance(node, ast.JoinedStr):
            parts = [self.expression(part) for part in node.values]
            joined = self.node(node, 'construct', '拼接文本',
                               [f'片段 {i+1}' for i in range(len(parts))], value_type='str')
            for i, part in enumerate(parts): self.edge(part, joined, port=i)
            return self.result_value(node, joined, '格式化字符串')
        if isinstance(node, ast.FormattedValue):
            value = self.expression(node.value)
            spec = self.expression(node.format_spec) if node.format_spec else None
            conversion = {114: '!r', 115: '!s', 97: '!a'}.get(node.conversion, '')
            formatted = self.node(node, 'format', f'格式化{conversion}', ['值', '格式'] if spec else ['值'],
                                  value_type='str')
            self.edge(value, formatted)
            self.edge(spec, formatted, port=1)
            return self.result_value(node, formatted, '格式化后的文本')
        if isinstance(node, ast.BinOp):
            children = [self.expression(node.left), self.expression(node.right)]
            result = self.node(node, 'operator', OPS.get(type(node.op).__name__, type(node.op).__name__), ['左侧', '右侧'], operator=type(node.op).__name__)
        elif isinstance(node, ast.UnaryOp):
            children = [self.expression(node.operand)]
            result = self.node(node, 'operator', OPS.get(type(node.op).__name__, type(node.op).__name__), ['操作数'], operator=type(node.op).__name__)
        elif isinstance(node, ast.BoolOp):
            # Conditional evaluation is explicit: later values are guarded, not
            # drawn as unconditional parallel inputs to a giant boolean block.
            left = self.expression(node.values[0])
            for right_ast in node.values[1:]:
                gate = self.node(node, 'condition', '检查真值（短路）', ['前一个值'])
                self.edge(left, gate)
                right = self.expression(right_ast)
                result = self.node(node, 'operator', OPS[type(node.op).__name__], ['左侧', '右侧'], operator=type(node.op).__name__)
                self.edge(left, result, port=0)
                self.edge(right, result, port=1)
                self.edge(gate, right, 'guard', '为真才求值' if isinstance(node.op, ast.And) else '为假才求值')
                self.edge(gate, result, 'guard', '否则直接使用前值')
                left = self.result_value(node, result, '短路结果')
            return left
        elif isinstance(node, ast.Compare):
            left_ast = node.left
            left = self.expression(left_ast)
            checks = []
            for op, rhs in zip(node.ops, node.comparators):
                right = self.expression(rhs)
                sign = OPS.get(type(op).__name__, type(op).__name__)
                result = self.node(node, 'operator', sign, ['左侧', '右侧'],
                                   operator=type(op).__name__,
                                   preview=f'{self.text(left_ast)} {sign} {self.text(rhs)}')
                self.edge(left, result, port=0)
                self.edge(right, result, port=1)
                if checks:
                    self.edge(checks[-1], right, 'guard', '前次比较成立才继续')
                checks.append(self.result_value(node, result, '比较结果'))
                left, left_ast = right, rhs
            if len(checks) == 1:
                return checks[0]
            result = self.node(node, 'operator', '所有比较成立', [f'比较 {i+1}' for i in range(len(checks))])
            for i, child in enumerate(checks): self.edge(child, result, port=i)
            return self.result_value(node, result, '比较结果')
        elif isinstance(node, ast.Call):
            function = self.expression(node.func)
            children = [function]
            labels = ['函数']
            for i, argument in enumerate(node.args):
                value = self.expression(argument)
                passed = self.node(argument, 'argument', f'传入参数 {i+1}', ['值'], argument_index=i)
                self.edge(value, passed)
                children.append(passed); labels.append(f'参数 {i+1}')
            for keyword in node.keywords:
                value = self.expression(keyword.value)
                passed = self.node(keyword.value, 'argument', f'传入 {keyword.arg or "**参数"}', ['值'])
                self.edge(value, passed)
                children.append(passed); labels.append(keyword.arg or '**参数')
            name = self.text(node.func)
            result = self.node(node, 'call', '调用', labels, function=name)
            for i, child in enumerate(children): self.edge(child, result, port=i)
            self.calls.append((result, name, self.scope))
            received = self.node(node, 'receive', '接收返回', ['返回值'], function=name)
            self.edge(result, received)
            value = self.result_value(node, received, '返回的值')
            self.call_results[result] = received
            return value
        elif isinstance(node, ast.Attribute):
            obj = self.expression(node.value)
            name = self.node(node, 'literal', node.attr, role='属性名', literal_type='str')
            operation = self.node(node, 'lookup', '定位属性', ['对象', '属性名'])
            self.edge(obj, operation, port=0); self.edge(name, operation, port=1)
            location = self.result_value(node, operation, '属性位置')
            read = self.node(node, 'read', '取值', ['属性位置'])
            self.edge(location, read)
            return self.result_value(node, read, f'{node.attr} 的值')
        elif isinstance(node, ast.Subscript):
            obj, index = self.expression(node.value), self.expression(node.slice)
            operation = self.node(node, 'lookup', '定位元素', ['容器', '索引'])
            self.edge(obj, operation, port=0); self.edge(index, operation, port=1)
            location = self.result_value(node, operation, '元素位置')
            read = self.node(node, 'read', '取值', ['元素位置'])
            self.edge(location, read)
            return self.result_value(node, read, '元素的值')
        elif isinstance(node, (ast.List, ast.Tuple, ast.Set, ast.Dict)):
            children = []
            rows = []
            if isinstance(node, ast.Dict):
                title = '字典'
                for i, (key, value) in enumerate(zip(node.keys, node.values)):
                    key_id = self.expression(key) if key is not None else None
                    value_id = self.expression(value)
                    child = value_id if value_id in self.collections else None
                    label = self.text(key) if key is not None else '**'
                    rows.append(dict(label=label, collection=child,
                                     **({'code': self.text(value) or ast.unparse(value)} if child is None else {})))
                    entry = self.node(value, 'element', f'键值对 {i}', ['键', '值'],
                                      entry_key=label if key is not None else None,
                                      index=i, spread=key is None, collection_id=child, value_type='dict_entry')
                    self.edge(key_id, entry, port=0)
                    self.edge(value_id, entry, port=1)
                    children.append(entry)
            else:
                title = {ast.List: '列表', ast.Tuple: '元组', ast.Set: '集合'}[type(node)]
                for i, element in enumerate(node.elts):
                    value = self.expression(element)
                    child = value if value in self.collections else None
                    rows.append(dict(label=f'[{i}]', collection=child,
                                     **({'code': self.text(element) or ast.unparse(element)} if child is None else {})))
                    slot = self.node(element, 'element', f'元素 {i}', ['值'], index=i, collection_id=child)
                    self.edge(value, slot); children.append(slot)
            value_type = type(node).__name__.lower()
            operation = self.node(node, 'construct', f'建立{title}', [f'元素 {i}' for i in range(len(children))],
                                  value_type=value_type)
            for i, child in enumerate(children): self.edge(child, operation, port=i)
            result = self.node(node, 'container', title, ['内容'], value_type=value_type)
            self.collections[result] = {'type': title, 'rows': rows}
            self.edge(operation, result)
            return result
        elif isinstance(node, ast.IfExp):
            test = self.expression(node.test)
            yes, no = self.expression(node.body), self.expression(node.orelse)
            gate = self.node(node, 'condition', '按条件取一个值', ['条件', '成立时', '不成立时'])
            self.edge(test, gate, port=0); self.edge(yes, gate, port=1); self.edge(no, gate, port=2)
            self.edge(test, yes, 'guard', '成立'); self.edge(test, no, 'guard', '不成立')
            return self.result_value(node, gate, '选出的值')
        else:
            name = type(node).__name__
            self.warnings.append(f'第 {getattr(node, "lineno", 1)} 行：{name} 尚未细分')
            return self.node(node, 'unsupported', f'尚未细分：{name}')
        for i, child in enumerate(children): self.edge(child, result, port=i)
        return self.result_value(node, result, '运算结果')

    def store(self, target, value):
        if isinstance(target, (ast.Tuple, ast.List)):
            unpack = self.node(target, 'operator', '解包元素', ['值'])
            self.edge(value, unpack)
            ends = [self.store(t, unpack) for t in target.elts]
            return ends[-1] if ends else unpack
        children = []
        if isinstance(target, ast.Attribute): children = [self.expression(target.value)]
        elif isinstance(target, ast.Subscript): children = [self.expression(target.value), self.expression(target.slice)]
        label = self.text(target)
        result = self.node(target, 'write', '=', ['新值', *(['对象'] if children else []), *(['索引'] if len(children) > 1 else [])], symbol=label)
        self.edge(value, result, port=0)
        for i, child in enumerate(children): self.edge(child, result, port=i+1)
        variable = self.node(target, 'symbol', label, ['保存的值'], symbol=label,
            assignment_line=getattr(target, 'lineno', 1), operation=result)
        self.edge(result, variable, 'binding', '保存')
        if isinstance(target, ast.Name): self.bindings[target.id] = variable
        return result

    def block(self, body, tails):
        for stmt in body:
            previous_statement = self.statement
            self.statement = stmt
            try:
                kind = type(stmt)
                if isinstance(stmt, ast.Try):
                    tails = self.try_statement(stmt, tails)
                    continue
                if isinstance(stmt, (ast.With, ast.AsyncWith)):
                    if isinstance(stmt, ast.AsyncWith):
                        self.warnings.append(f'第 {stmt.lineno} 行：异步上下文的等待过程尚未细分')
                    tails = self.with_statement(stmt, tails)
                    continue
                if isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                    is_class = isinstance(stmt, ast.ClassDef)
                    defined = self.node(stmt, 'definition', '定义类' if is_class else '定义函数', function=stmt.name,
                                        value_type='function' if not is_class and not stmt.decorator_list else None)
                    self.flow(tails, defined)
                    named = self.node(stmt, 'symbol', stmt.name, ['定义'], symbol=stmt.name)
                    self.edge(defined, named, 'binding', '函数名')
                    self.bindings[stmt.name] = named
                    old_scope, old_loops, old_bindings = self.scope, self.loops, self.bindings
                    old_error, old_cleanups = self.exception_target, self.cleanups
                    self.exception_target, self.cleanups = None, []
                    self.bindings = {}
                    self.scope = f'{old_scope}/{stmt.name}@{stmt.lineno}'
                    self.scopes.append({'id': self.scope, 'name': stmt.name, 'line': stmt.lineno})
                    self.scope_bodies[self.scope] = stmt.body
                    entry = self.node(stmt, 'entry', f'{stmt.name} 入口')
                    self.definitions[(old_scope, stmt.name)] = entry
                    self.loops = []
                    inner_tails = [(entry, '')]
                    if isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef)):
                        args = [*stmt.args.posonlyargs, *stmt.args.args, *stmt.args.kwonlyargs]
                        if stmt.args.vararg: args.append(stmt.args.vararg)
                        if stmt.args.kwarg: args.append(stmt.args.kwarg)
                        for arg in args:
                            parameter = self.node(arg, 'parameter', '接收参数', ['传来的值'], symbol=arg.arg)
                            self.edge(entry, parameter, 'binding', arg.arg)
                            variable = self.node(arg, 'symbol', arg.arg, ['参数值'], symbol=arg.arg)
                            self.edge(parameter, variable, 'binding', '参数值')
                            self.bindings[arg.arg] = variable
                    self.block(stmt.body, inner_tails)
                    self.scope, self.loops, self.bindings = old_scope, old_loops, old_bindings
                    self.exception_target, self.cleanups = old_error, old_cleanups
                    tails = [(defined, '')]
                    continue
                if isinstance(stmt, ast.If):
                    value = self.expression(stmt.test)
                    truth = self.node(stmt.test, 'truth', '检查真值', ['条件值'])
                    self.edge(value, truth)
                    truth_value = self.result_value(stmt.test, truth, '真值结果')
                    decision = self.node(stmt, 'condition', '条件选路', ['条件结果'],
                                         preview=self.text(stmt.test))
                    self.edge(truth_value, decision); self.flow(tails, decision)
                    yes_path = self.node(stmt, 'branch', '成立', ['通路'])
                    no_path = self.node(stmt, 'branch', '不成立', ['通路'])
                    self.edge(decision, yes_path, 'guard', '成立')
                    self.edge(decision, no_path, 'guard', '不成立')
                    original = dict(self.bindings)
                    yes = self.block(stmt.body, [(yes_path, '成立')])
                    yes_bindings = dict(self.bindings)
                    self.bindings = dict(original)
                    no = self.block(stmt.orelse, [(no_path, '不成立')]) if stmt.orelse else [(no_path, '不成立')]
                    no_bindings = dict(self.bindings)
                    if not yes and not no:
                        self.bindings = original
                        tails = []
                    else:
                        join = self.node(stmt, 'join', '分支汇合', region_phase='end', line=getattr(stmt, 'end_lineno', stmt.lineno))
                        self.flow([*yes, *no], join)
                        if not yes:
                            self.bindings = no_bindings
                        elif not no:
                            self.bindings = yes_bindings
                        else:
                            self.bindings = {}
                            for name in sorted(yes_bindings.keys() | no_bindings.keys()):
                                left, right = yes_bindings.get(name), no_bindings.get(name)
                                if left == right:
                                    if left is not None: self.bindings[name] = left
                                else:
                                    if name not in needed_after(self, stmt): continue
                                    merged = self.node(stmt, 'variable', f'{name}：使用所选分支的值', ['成立时', '不成立时'], region_phase='end', symbol=name, line=getattr(stmt, 'end_lineno', stmt.lineno))
                                    self.edge(left, merged, 'binding', '成立时', port=0)
                                    self.edge(right, merged, 'binding', '不成立时', port=1)
                                    if left is None or right is None:
                                        self.warnings.append(f'变量 {name} 在其中一条分支可能未赋值')
                                    self.bindings[name] = merged
                        tails = [(join, '')]
                    continue
                if isinstance(stmt, (ast.While, ast.For, ast.AsyncFor)):
                    # Loop slots represent the value at the start of each iteration.
                    # Feedback edges carry updates, rather than pretending the first
                    # iteration's assignment is the value used by every iteration.
                    original = dict(self.bindings)
                    collector = StoredNames()
                    for child in stmt.body: collector.visit(child)
                    if isinstance(stmt, (ast.For, ast.AsyncFor)): collector.visit(stmt.target)
                    slots = {}
                    _, first_reads = read_before_write(stmt.body, set() if isinstance(stmt, ast.While) else names(stmt.target).stored)
                    if isinstance(stmt, ast.While): first_reads.update(names(stmt.test).loaded)
                    carried = collector.names & (first_reads | needed_after(self, stmt))
                    for name in sorted(carried):
                        slot = self.node(stmt, 'variable', f'循环中的 {name}', ['初始值', '下一轮的值'], symbol=name)
                        self.edge(original.get(name), slot, 'binding', '初始值', port=0)
                        slots[name] = slot; self.bindings[name] = slot
                    value = self.expression(stmt.test if isinstance(stmt, ast.While) else stmt.iter)
                    header = self.node(stmt, 'condition', '循环检查' if isinstance(stmt, ast.While) else '取下一个元素', ['条件' if isinstance(stmt, ast.While) else '可迭代对象'],
                                       preview=self.text(stmt.test) if isinstance(stmt, ast.While) else f'{self.text(stmt.target)} in {self.text(stmt.iter)}')
                    self.edge(value, header); self.flow(tails, header)
                    exit_node = self.node(stmt, 'join', '离开循环', region_phase='end', line=getattr(stmt, 'end_lineno', stmt.lineno))
                    self.loops.append((header, exit_node, set(slots)))
                    loop_tails = [(header, '成立' if isinstance(stmt, ast.While) else '有元素')]
                    if isinstance(stmt, (ast.For, ast.AsyncFor)):
                        assigned = self.store(stmt.target, header)
                        self.flow(loop_tails, assigned); loop_tails = [(assigned, '')]
                    body_tails = self.block(stmt.body, loop_tails)
                    self.flow([(n, '下一轮') for n, _ in body_tails], header)
                    self.loops.pop()
                    for name, slot in slots.items():
                        updated = self.bindings.get(name)
                        if updated != slot: self.edge(updated, slot, 'binding', '下一轮的值', port=1)
                    self.bindings = {**original, **slots}
                    always_true = isinstance(stmt, ast.While) and isinstance(stmt.test, ast.Constant) and stmt.test.value is True
                    exhaustion = [] if always_true else [(header, '结束')]
                    exhausted = self.block(stmt.orelse, exhaustion) if stmt.orelse else exhaustion
                    self.flow(exhausted, exit_node)
                    tails = [(exit_node, '')]
                    continue
                if isinstance(stmt, (ast.Assign, ast.AnnAssign, ast.AugAssign)):
                    if isinstance(stmt, ast.AugAssign):
                        left = self.expression(stmt.target)
                        right = self.expression(stmt.value)
                        value = self.node(stmt, 'operator', OPS.get(type(stmt.op).__name__, '?'), ['原值', '右侧'],
                                          operator=type(stmt.op).__name__)
                        self.edge(left, value, port=0); self.edge(right, value, port=1)
                        value = self.result_value(stmt, value, '运算结果')
                    else:
                        value = self.expression(stmt.value)
                    targets = stmt.targets if isinstance(stmt, ast.Assign) else [stmt.target]
                    endpoint = None
                    for target in targets:
                        endpoint = self.store(target, value)
                        self.flow(tails, endpoint); tails = [(endpoint, '')]
                    continue
                if isinstance(stmt, ast.Expr):
                    if isinstance(stmt.value, ast.Constant) and isinstance(stmt.value.value, str):
                        endpoint = self.node(stmt, 'comment', stmt.value.value, role='程序说明')
                    else:
                        endpoint = self.expression(stmt.value)
                elif isinstance(stmt, ast.Raise):
                    value = self.expression(stmt.exc)
                    cause = self.expression(stmt.cause)
                    endpoint = self.node(stmt, 'raise', '抛出异常' if stmt.exc else '重新抛出异常', ['异常', '原因'] if cause else ['异常'])
                    self.edge(value, endpoint); self.edge(cause, endpoint, port=1)
                    self.flow(tails, endpoint)
                    tails = []; continue
                elif isinstance(stmt, (ast.Import, ast.ImportFrom)):
                    module = stmt.module if isinstance(stmt, ast.ImportFrom) else ', '.join(a.name for a in stmt.names)
                    endpoint = self.node(stmt, 'import', f'导入 {module}', [a.name for a in stmt.names])
                    for i, alias in enumerate(stmt.names):
                        if alias.name == '*': continue
                        name = alias.asname or (alias.name if isinstance(stmt, ast.ImportFrom) else alias.name.split('.')[0])
                        symbol = self.node(stmt, 'symbol', name, ['导入的对象'], symbol=name)
                        self.edge(endpoint, symbol, 'binding', alias.name, port=i)
                        self.bindings[name] = symbol
                elif isinstance(stmt, ast.Return):
                    value = self.expression(stmt.value)
                    endpoint = self.node(stmt, 'pending_return' if self.cleanups else 'return', '准备返回' if self.cleanups else '返回给调用处', ['返回值'])
                    self.edge(value, endpoint); self.flow(tails, endpoint)
                    self.abrupt(stmt, endpoint, 'return', value=value)
                    tails = []; continue
                elif isinstance(stmt, (ast.Break, ast.Continue)):
                    endpoint = self.node(stmt, 'control', '跳出循环' if isinstance(stmt, ast.Break) else '开始下一轮')
                    self.flow(tails, endpoint)
                    if self.loops: self.abrupt(stmt, endpoint, 'break' if isinstance(stmt, ast.Break) else 'continue', self.loops[-1][1 if isinstance(stmt, ast.Break) else 0])
                    tails = []; continue
                elif isinstance(stmt, (ast.Import, ast.ImportFrom, ast.Pass, ast.Global, ast.Nonlocal)):
                    endpoint = self.node(stmt, 'definition', self.text(stmt))
                else:
                    self.warnings.append(f'第 {stmt.lineno} 行：{kind.__name__} 尚未细分')
                    endpoint = self.node(stmt, 'unsupported', f'尚未细分：{kind.__name__}')
                self.flow(tails, endpoint); tails = [(endpoint, '')]
            finally:
                self.statement = previous_statement
        return tails

    def build(self, mode="full"):
        tree = ast.parse(self.source)
        if sum(1 for _ in ast.walk(tree)) > 7000:
            raise ValueError('代码过大，请按文件拆分后查看图形')
        if mode == "overview":
            return {"reading": reading_flow(tree.body)}
        self.lesson_nodes = {(n.lineno, n.col_offset, type(n).__name__): n for n in ast.walk(tree) if isinstance(n, (ast.stmt, ast.ExceptHandler))}
        self.scope_bodies['main'] = tree.body
        self.block(tree.body, [])
        nodes_by_id = {node['id']: node for node in self.nodes}
        returns_by_scope = {}
        for node in self.nodes:
            if node['kind'] == 'return':
                returns_by_scope.setdefault(node['scope'], []).append(node['id'])
        for call, name, scope in self.calls:
            search = scope
            while True:
                # The current function lives in its parent's symbol scope.
                definition = self.definitions.get((search, name))
                if definition:
                    destination_scope = nodes_by_id[definition]['scope']
                    recursive = destination_scope == scope
                    self.edge(call, definition, 'call', '递归调用' if recursive else '进入函数')
                    for returned in returns_by_scope.get(destination_scope, ()):
                        self.edge(returned, self.call_results[call], 'return', '返回值')
                    break
                if '/' not in search: break
                search = search.rsplit('/', 1)[0]
        annotate_value_types(self.nodes, self.edges)
        self.layout()
        graph = {'whole_views': whole_views(self, self.scope_bodies), 'line_views': self.line_views(), 'granularity': 'atomic', 'nodes': self.nodes, 'edges': self.edges, 'scopes': self.scopes, 'collections': self.collections,
                'warnings': list(dict.fromkeys(self.warnings))}

        if mode == "nodes":
            calls = [edge for edge in self.edges if edge['kind'] == 'call']
            graph['edges'] = calls
            graph['nodes'] = [{key: nodes_by_id[target][key] for key in ('id', 'scope', 'line')}
                              for target in dict.fromkeys(edge['to'] for edge in calls)]
        else:
            graph['reading'] = reading_flow(tree.body)
        return graph

    def line_views(self):
        views = []
        source_lines = self.source.splitlines()
        for scope in self.scopes:
            nodes = [n for n in self.nodes if n['scope'] == scope['id']]
            lookup = {n['id']: n for n in nodes}
            local_edges = [e for e in self.edges if e['from'] in lookup and e['to'] in lookup]
            for line in sorted({n['line'] for n in nodes}):
                core = {n['id'] for n in nodes if n['line'] == line}
                visible, queue = set(core), list(core)
                while queue:
                    target = queue.pop()
                    for edge in local_edges:
                        if edge['to'] != target or edge['kind'] not in ('data', 'binding'):
                            continue
                        source = lookup[edge['from']]
                        if source['id'] in visible: continue
                        visible.add(source['id'])
                        # Carry variable origins into the selected line, without
                        # expanding every assignment earlier in the program.
                        if source['kind'] not in ('symbol', 'literal', 'variable', 'container', 'parameter'):
                            queue.append(source['id'])
                detailed = GraphBuilder('')
                detailed.nodes = [{**n, 'context': n['id'] not in core} for n in nodes if n['id'] in visible]
                detailed.edges = [e for e in local_edges if e['from'] in visible and e['to'] in visible]
                detailed.scopes = [{'id': scope['id'], 'name': scope['name']}]
                detailed.layout()
                owners = [n.get('statement_id') for n in nodes if n['line'] == line and n.get('statement_id')]
                owner = next((o for o in owners if o.rsplit(':', 3)[1] == str(line)), owners[0] if owners else '')
                parts = owner.rsplit(':', 3)
                statement = self.lesson_nodes.get((int(parts[1]), int(parts[2]), parts[3])) if len(parts) == 4 else None
                views.append({'scope': scope['id'], 'line': line, 'teaching': lesson([] if any(n['kind'] == 'entry' and n['line'] == line for n in nodes) else [statement] if statement else []),
                    'code': source_lines[line - 1].strip() if 0 < line <= len(source_lines) else '',
                    'nodes': detailed.nodes, 'edges': detailed.edges,
                    'width': detailed.scopes[0]['width'], 'height': detailed.scopes[0]['height']})
        return views

    def layout(self):
        # Layer by value dependencies across the entire scope, not by source
        # lines. Back edges (loop feedback) never increase ranks.
        by_id = {n['id']: n for n in self.nodes}
        index = {n['id']: i for i, n in enumerate(self.nodes)}
        for n in self.nodes:
            count = len(n['inputs'])
            n['width'] = max(120, min(320, 40 + len(n['title']) * 15)) if n['kind'] in ('symbol', 'reference') else 90 if n['kind'] == 'literal' else 92 if n['kind'] == 'read' else 72 if n['kind'] == 'write' else 80 if n['kind'] == 'operator' else 130 if n['kind'] == 'value' else 160
            if n['kind'] == 'literal' and n.get('literal_type') == 'str':
                n['width'] = max(160, min(360, 28 + len(n['title']) * 8))
            if n['kind'] == 'comment': n['width'] = 360
            n['height'] = max(96 if n['kind'] == 'comment' else 88, 54 + min(count, 6) * 16)
        for scope in self.scopes:
            nodes = [n for n in self.nodes if n['scope'] == scope['id']]
            ids = {n['id'] for n in nodes}
            dependencies = [e for e in self.edges if e['from'] in ids and e['to'] in ids
                            and e['kind'] in ('data', 'binding', 'guard')
                            and index[e['from']] < index[e['to']]]
            parents = {n['id']: [] for n in nodes}
            children = {n['id']: [] for n in nodes}
            for e in dependencies:
                parents[e['to']].append(e['from'])
                children[e['from']].append(e['to'])
            ranks = {}
            for n in nodes:
                ranks[n['id']] = max((ranks[p] + 1 for p in parents[n['id']]), default=0)
            layers = {}
            for n in nodes:
                layers.setdefault(ranks[n['id']], []).append(n)
            # Barycentric sweeps keep the same inputs on the same side of an
            # operation and reduce crossings without moving source identities.
            order = {n['id']: i for layer in layers.values() for i, n in enumerate(layer)}
            for _ in range(4):
                for rank in sorted(layers):
                    layers[rank].sort(key=lambda n: (
                        sum(order[p] for p in parents[n['id']]) / len(parents[n['id']])
                        if parents[n['id']] else order[n['id']], n['line']))
                    for i, n in enumerate(layers[rank]): order[n['id']] = i
                for rank in sorted(layers, reverse=True):
                    layers[rank].sort(key=lambda n: (
                        sum(order[c] for c in children[n['id']]) / len(children[n['id']])
                        if children[n['id']] else order[n['id']], n['line']))
                    for i, n in enumerate(layers[rank]): order[n['id']] = i
            x = 20
            max_height = max((sum(n['height'] for n in layer) + 24 * (len(layer)-1)
                              for layer in layers.values()), default=100)
            for rank in sorted(layers):
                layer = layers[rank]
                layer_height = sum(n['height'] for n in layer) + 24 * (len(layer)-1)
                y = 24 + (max_height - layer_height) / 2
                for n in layer:
                    n['x'], n['y'] = x, y
                    y += n['height'] + 24
                x += max(n['width'] for n in layer) + 24
            # Align single-result layers with the average position of their
            # inputs. Keep each column collision-free after each adjustment.
            for _ in range(2):
                for rank in sorted(layers):
                    layer = layers[rank]
                    cursor = 24
                    for n in layer:
                        linked = parents[n['id']]
                        if linked:
                            center = sum(by_id[p]['y'] + by_id[p]['height']/2 for p in linked) / len(linked)
                            n['y'] = max(cursor, center - n['height']/2)
                        else:
                            n['y'] = max(cursor, n['y'])
                        cursor = n['y'] + n['height'] + 24
            scope['width'] = max((n['x'] + n['width'] + 20 for n in nodes), default=500)
            scope['height'] = max((n['y'] + n['height'] + 24 for n in nodes), default=240)

def code_graph(source, mode="full"):
    return GraphBuilder(source).build(mode)


def main():
    for line in sys.stdin:
        request_id = None
        try:
            request = json.loads(line)
            request_id = request.get('id')
            source = request['source']
            if not isinstance(source, str) or len(source) > 150_000:
                raise ValueError('代码过大或内容无效')
            response = {'id': request_id, 'graph': code_graph(source, request.get('mode', 'full'))}
        except SyntaxError as error:
            response = {'id': request_id, 'error': {'line': error.lineno, 'message': error.msg}}
        except (ValueError, TypeError, KeyError, RecursionError) as error:
            response = {'id': request_id, 'error': {'message': str(error)}}
        print(json.dumps(response, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
