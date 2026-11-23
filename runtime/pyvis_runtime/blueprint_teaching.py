"""Deterministic plain-language reading aids, separate from actual execution."""
import ast


def text(node):
    return ast.unparse(node)[:100] if node is not None else ''


def condition(node):
    if isinstance(node, ast.Constant) and isinstance(node.value, bool):
        return '始终成立' if node.value else '始终不成立'
    if isinstance(node, ast.Compare) and len(node.ops) == 1:
        words = {ast.Lt: '小于', ast.LtE: '小于或等于', ast.Gt: '大于', ast.GtE: '大于或等于',
                 ast.Eq: '等于', ast.NotEq: '不等于', ast.In: '属于', ast.NotIn: '不属于',
                 ast.Is: '引用同一对象', ast.IsNot: '引用不同对象'}
        return f'{text(node.left)} {words.get(type(node.ops[0]), text(node.ops[0]))} {text(node.comparators[0])}'
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not): return f'{text(node.operand)} 不成立'
    return f'{text(node)} 的判断结果为 True'


def input_steps(node):
    operations = []
    while isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
        label = {'strip': '移除首尾空白字符', 'lower': '将字母转换为小写', 'upper': '将字母转换为大写'}.get(node.func.attr)
        if label is None: return []
        operations.insert(0, (label, '.' + node.func.attr))
        node = node.func.value
    return [('读取用户输入', 'input'), *operations] if isinstance(node, ast.Call) and text(node.func) == 'input' else []


def calculation(node):
    if not isinstance(node, ast.BinOp): return text(node)
    left, right = text(node.left), text(node.right)
    return {ast.Add: f'将 {left} 与 {right} 相加', ast.Sub: f'从 {left} 中减去 {right}',
            ast.Mult: f'将 {left} 与 {right} 相乘', ast.Div: f'用 {left} 除以 {right}',
            ast.Mod: f'计算 {left} 除以 {right} 的余数'}.get(type(node.op), f'计算 {text(node)}')


def referenced_names(node):
    found = []
    class References(ast.NodeVisitor):
        def visit_Name(self, n):
            if isinstance(n.ctx, ast.Load) and n.id not in found: found.append(n.id)
        def visit_Call(self, n):
            if isinstance(n.func, ast.Attribute): self.visit(n.func.value)
            for value in n.args: self.visit(value)
            for item in n.keywords: self.visit(item.value)
    References().visit(node)
    return '、'.join(found[:3])


def summary(stmt):
    if isinstance(stmt, ast.AugAssign):
        target, value = text(stmt.target), text(stmt.value)
        if isinstance(stmt.op, ast.Add): return f'将 {value} 加到 {target}，更新 {target}'
        if isinstance(stmt.op, ast.Sub): return f'从 {target} 中减去 {value}，更新 {target}'
        if isinstance(stmt.op, ast.Mult): return f'将 {target} 乘以 {value}，更新 {target}'
        return f'更新 {target} 的值'
    if isinstance(stmt, (ast.Assign, ast.AnnAssign)):
        targets = stmt.targets if isinstance(stmt, ast.Assign) else [stmt.target]
        target, value = '、'.join(text(t) for t in targets), text(stmt.value)
        if input_steps(stmt.value): return f'读取并处理用户输入，赋给 {target}'
        if isinstance(stmt.value, ast.BinOp): return f'{calculation(stmt.value)}，将结果赋给 {target}'
        return f'将 {value} 赋给 {target}'
    if isinstance(stmt, ast.Expr):
        if isinstance(stmt.value, ast.Call):
            name = text(stmt.value.func)
            if name == 'print': return '输出内容到屏幕'
            if name == 'input': return '等待并读取用户输入'
            return f'调用 {name}'
        if isinstance(stmt.value, ast.Constant) and isinstance(stmt.value.value, str): return '程序说明'
    if isinstance(stmt, ast.While): return '循环条件始终成立' if isinstance(stmt.test, ast.Constant) and stmt.test.value is True else f'循环条件：{condition(stmt.test)}'
    if isinstance(stmt, (ast.For, ast.AsyncFor)):
        if isinstance(stmt.iter, ast.Call) and text(stmt.iter.func) == 'range' and len(stmt.iter.args) == 1 and isinstance(stmt.iter.args[0], ast.Constant) and isinstance(stmt.iter.args[0].value, int):
            return f'重复执行循环体 {max(0, stmt.iter.args[0].value)} 次'
        return f'遍历 {text(stmt.iter)}，依次处理每个元素'
    if isinstance(stmt, ast.If): return f'判断条件：{condition(stmt.test)}'
    if isinstance(stmt, ast.Break): return '退出当前循环'
    if isinstance(stmt, ast.Continue): return '结束本轮循环，进入下一轮'
    if isinstance(stmt, ast.Return): return f'返回 {text(stmt.value)}' if stmt.value else '结束函数，返回 None'
    if isinstance(stmt, ast.Try): return '执行受保护代码，发生异常时进入处理分支'
    if isinstance(stmt, (ast.With, ast.AsyncWith)): return '使用上下文管理器，退出时执行清理'
    if isinstance(stmt, ast.ExceptHandler): return '处理匹配此类型的异常'
    if isinstance(stmt, (ast.Import, ast.ImportFrom)): return '导入后续代码需要的模块或对象'
    if isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef)): return f'定义函数 {stmt.name}'
    if isinstance(stmt, ast.Raise): return '抛出异常，交由外层处理'
    return f'执行第 {getattr(stmt, "lineno", 1)} 行的操作'


def falls_through(body):
    for stmt in body:
        if isinstance(stmt, (ast.Break, ast.Continue, ast.Return, ast.Raise)): return False
        if isinstance(stmt, ast.If) and stmt.orelse and not falls_through(stmt.body) and not falls_through(stmt.orelse): return False
        if isinstance(stmt, (ast.With, ast.AsyncWith)) and not falls_through(stmt.body): return False
        if isinstance(stmt, ast.Try) and stmt.finalbody and not falls_through(stmt.finalbody): return False
    return True


def continues_this_loop(body):
    for stmt in body:
        if isinstance(stmt, ast.Continue): return True
        if isinstance(stmt, (ast.For, ast.AsyncFor, ast.While, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)): continue
        for attr in ('body', 'orelse', 'finalbody'):
            if continues_this_loop(getattr(stmt, attr, [])): return True
        for handler in getattr(stmt, 'handlers', []):
            if continues_this_loop(handler.body): return True
    return False


def lesson(statements, section_title=''):
    if not statements: return dict(title='接收函数参数', explanation='调用方提供参数后，函数体使用这些参数执行内部语句。', steps=[], role='receive')
    stmt = statements[0]
    result = dict(title=summary(stmt), line=stmt.lineno, code=text(stmt),
                  explanation='按箭头顺序读取数据、执行操作，再将结果传递给后续步骤。', steps=[], role='action')
    def step(label, source, kind='action', target_kind=None):
        return dict(label=label, line=source.lineno, kind=kind, target_kind=target_kind)
    if section_title == '离开循环':
        result.update(title='当前循环结束', explanation='继续执行循环体之后的代码。', role='finish')
    elif section_title == '分支汇合':
        result.update(title='分支执行结束，继续后续步骤', explanation='一次判断只选择一条分支。后续代码使用该分支产生的结果。', role='finish')
    elif section_title == '异常分派（出错时）':
        result.update(title='选择异常处理分支', explanation='发生异常后，按声明顺序选择第一个与异常类型匹配的处理分支。', role='error')
    elif '退出上下文' in section_title or section_title == '准备执行 finally':
        result.update(title='执行退出前的清理操作', explanation='先执行清理，再继续正常流程、返回、退出循环，或向外传递异常。', role='finish')
    elif isinstance(stmt, (ast.While, ast.For, ast.AsyncFor)):
        result['role'] = 'repeat'
        result['explanation'] = '每轮开始前判断条件。条件成立时执行循环体，正常完成本轮后再次判断；条件不成立时退出循环。' if isinstance(stmt, ast.While) else '每次读取一个元素并执行循环体；所有元素处理完成后，继续后续代码。'
        if isinstance(stmt, ast.While) and isinstance(stmt.test, ast.Constant) and stmt.test.value is True:
            result['explanation'] = '条件始终成立，因此会重复执行循环体；退出循环需要执行 break、return 或发生异常等情况。'
        if isinstance(stmt, ast.While) and referenced_names(stmt.test):
            result['explanation'] = f'读取变量 {referenced_names(stmt.test)} 的当前值并判断条件。条件成立时执行循环体，正常完成本轮后再次判断；不成立时退出。'
        result['steps'] = [step('判断循环条件' if isinstance(stmt, ast.While) else '读取下一个元素', stmt, 'check', 'condition')]
        result['steps'] += [step(summary(child), child) for child in stmt.body[:3]]
        if len(stmt.body) > 3: result['steps'].append(step('继续执行本轮后续步骤', stmt.body[3]))
        if falls_through(stmt.body) or continues_this_loop(stmt.body):
            result['steps'].append(step('返回条件判断', stmt, 'repeat', 'condition'))
    elif isinstance(stmt, ast.If):
        alternative = '继续判断后续条件' if stmt.orelse and isinstance(stmt.orelse[0], ast.If) else '执行 else 分支' if stmt.orelse else '跳过此分支，继续后续代码'
        result.update(role='check', explanation=f'条件判断结果为 True 时执行 if 分支，为 False 时{alternative}。一次判断只选择一条分支。')
        result['steps'] = [step('判断条件', stmt, 'check', 'condition')]
        if stmt.body: result['steps'].append(step(f'条件成立：{summary(stmt.body[0])}', stmt.body[0], 'yes'))
        if stmt.orelse: result['steps'].append(step(f'条件不成立：{summary(stmt.orelse[0])}', stmt.orelse[0], 'no'))
    elif isinstance(stmt, (ast.Assign, ast.AnnAssign, ast.AugAssign)):
        targets = stmt.targets if isinstance(stmt, ast.Assign) else [stmt.target]
        target = '、'.join(text(t) for t in targets)
        result['explanation'] = f'先计算右侧表达式，再将结果赋给 {target}。后续代码可以通过该名称读取结果。'
        take = step('读取所需数据', stmt, 'input', 'read')
        store = step(f'赋值给 {target}', stmt, 'store', 'write')
        result['steps'] = [take, store]
        if isinstance(stmt, ast.AugAssign):
            result['explanation'] = f'读取 {target} 的当前值，与右侧数据进行运算，再更新 {target}。'
            result['steps'].insert(1, step(summary(stmt), stmt, 'action', 'operator'))
        elif isinstance(stmt.value, ast.BinOp):
            calculate = step(calculation(stmt.value), stmt, 'action', 'operator')
            calculate['target_operator'] = {ast.Add: '+', ast.Sub: '−', ast.Mult: '×', ast.Div: '÷', ast.Mod: '%', ast.Pow: '**', ast.FloorDiv: '//'}.get(type(stmt.value.op))
            result['steps'].insert(1, calculate)
        elif isinstance(stmt.value, ast.Call):
            result['steps'].insert(1, step(f'调用 {text(stmt.value.func)}', stmt, 'action', 'call'))
        pipeline = input_steps(stmt.value)
        if pipeline:
            result['role'] = 'input'
            result['explanation'] = f'等待用户输入，按顺序处理输入的字符串，最后将结果赋给 {target}。'
            result['steps'] = [{**step(label, stmt, 'input', 'call'), 'function_suffix': suffix} for label, suffix in pipeline]
            result['steps'].append(step(f'赋值给 {target}', stmt, 'store', 'write'))
        if len(statements) > 1:
            all_targets = '、'.join(text(t) for child in statements for t in (child.targets if isinstance(child, ast.Assign) else [child.target]))
            result['explanation'] = f'按代码顺序为 {all_targets} 设置初始值，供后续步骤读取。'
            result['title'] = '设置变量初始值'
            result['steps'] = [step(summary(child), child, 'store', 'write') for child in statements]
    elif isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Call):
        name = text(stmt.value.func)
        if name == 'print':
            result.update(role='output', explanation='先准备输出内容，再调用 print 显示到屏幕，完成后继续执行下一步。')
            formatted = any(isinstance(n, ast.JoinedStr) for n in stmt.value.args)
            result['steps'] = [step('将值插入格式化字符串' if formatted else '准备输出内容', stmt, 'input', 'format' if formatted else 'argument'), step('输出到屏幕', stmt, 'output', 'call')]
        elif name == 'input': result.update(role='input', explanation='程序在此等待用户输入；读取完成后，继续执行后续代码。')
    elif isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef)):
        result['explanation'] = '函数将一组操作组织在同一名称下。定义时记录函数体，调用时才执行函数体中的语句。'
    elif isinstance(stmt, ast.Try):
        result.update(role='protect', explanation='先正常执行本段代码。发生错误或中断等异常时，再按异常类型选择处理分支。')
        if stmt.body: result['steps'] = [step('执行受保护代码', stmt.body[0], 'action')]
        if stmt.handlers: result['steps'].append(step('发生异常时进入处理分支', stmt.handlers[0], 'error'))
    elif isinstance(stmt, (ast.With, ast.AsyncWith)):
        result.update(role='prepare', explanation='先执行进入操作，再执行内部代码；离开时执行退出操作。常见用途是管理文件或临时计算设置。')
    elif isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Constant) and isinstance(stmt.value.value, str):
        result['explanation'] = stmt.value.value
    return result
