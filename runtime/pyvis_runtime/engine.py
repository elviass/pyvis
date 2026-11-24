from __future__ import annotations

import ast
import builtins
import contextlib
import io
from itertools import islice
import os
from pathlib import Path
import sys
import threading
import traceback
import types
import uuid
import weakref
from .source_encoding import decode_source


class RecordingLimit(Exception):
    pass


def exception_message(error):
    # A trace hook runs before Python finds the learner's exception handler.
    # Reading BaseException.args avoids invoking user formatters or properties.
    args = BaseException.args.__get__(error)
    if type(error) is SyntaxError or type(error) in (IndentationError, TabError):
        return SyntaxError.msg.__get__(error) or ''
    if not args or any(type(arg) not in (str, int, float, bool, type(None)) for arg in args):
        return ''
    if any(type(arg) is int and arg.bit_length() > 4096 for arg in args):
        return ''
    if len(args) == 1 and type(error) is not KeyError:
        return str(args[0])
    return repr(args[0] if len(args) == 1 else args)


class Instrument(ast.NodeTransformer):
    """Observe values after evaluation; never evaluate an expression twice."""
    def __init__(self, hook, control_tests):
        self.hook = hook
        self.control_tests = control_tests

    def visit(self, node):
        node = super().visit(node)
        if node in self.control_tests:
            # Keep Python's jump-context evaluation. Wrapping these tests in
            # a call can truth-test an operand twice, including user __bool__.
            return node
        supported = (ast.BinOp, ast.UnaryOp, ast.Compare, ast.BoolOp, ast.Call,
                     ast.Attribute, ast.Subscript, ast.Name)
        if not isinstance(node, supported) or not isinstance(getattr(node, 'ctx', ast.Load()), ast.Load):
            return node
        # Hook lookup is added after traversal, so generated calls aren't instrumented.
        call = ast.Call(func=ast.Name(id=self.hook, ctx=ast.Load()), args=[
            node, ast.Constant(node.lineno), ast.Constant(node.col_offset),
            ast.Constant(getattr(node, 'end_lineno', node.lineno)),
            ast.Constant(getattr(node, 'end_col_offset', node.col_offset)),
            ast.Constant(type(node).__name__),
        ], keywords=[])
        return ast.copy_location(call, node)

    # Suspension and comprehensions need a separate event model. Preserve their execution.
    def visit_GeneratorExp(self, node):
        return node

    def visit_Lambda(self, node):
        return node

    def visit_match_case(self, node):
        # Pattern lookups must stay as attribute expressions in the AST.
        if node.guard is not None:
            node.guard = self.visit(node.guard)
        node.body = [self.visit(stmt) for stmt in node.body]
        return node

    def generic_visit(self, node):
        # Annotations may be stringized or evaluated after the trace has ended.
        original = {name: node.__dict__.pop(name) for name in
                    ('annotation', 'returns', 'type_params') if name in node.__dict__}
        try:
            return super().generic_visit(node)
        finally:
            node.__dict__.update(original)

    def visit_TypeAlias(self, node):
        return node


class Snapshot:
    def __init__(self):
        self.objects = {}
        self.counter = 0

    def capture(self, frames, extra=()):
        heap = {}
        remaining = [500]

        def value(obj, depth=0):
            kind = type.__getattribute__(type(obj), '__name__')
            if type(obj) in (str, int, float, bool, type(None)):
                if type(obj) is str:
                    obj = obj[:2000]
                if type(obj) is float and (obj != obj or abs(obj) == float('inf')):
                    obj = str(obj)
                if type(obj) is int and obj.bit_length() > 4096:
                    obj = '<大整数>'
                return {'type': kind, 'value': obj}
            address = id(obj)
            registered = self.objects.get(address)
            if registered is not None:
                oid, stored, weak = registered
                if (stored() if weak else stored) is not obj:
                    registered = None
            if registered is None and remaining[0] <= 0:
                return {'type': kind, 'value': '<对象已截断>'}
            if registered is None:
                self.counter += 1
                oid = f'o{self.counter}'
                try:
                    stored = weakref.ref(obj)
                    weak = True
                except TypeError:
                    # Some builtin containers need a strong reference to avoid id reuse.
                    stored, weak = obj, False
                self.objects[address] = (oid, stored, weak)
            ref = {'type': kind, 'ref': oid}
            if oid in heap:
                return ref
            if remaining[0] <= 0:
                return {'type': kind, 'value': '<对象已截断>'}
            entry = {'id': oid, 'type': kind}
            heap[oid] = entry
            remaining[0] -= 1
            if depth >= 6:
                entry['truncated'] = True
                return ref
            if type(obj) in (list, tuple, set, frozenset):
                entry['items'] = [value(x, depth + 1) for x in islice(obj, 100)]
                entry['length'] = len(obj)
                entry['truncated'] = len(obj) > 100
            elif type(obj) is dict:
                entry['entries'] = [[value(k, depth+1), value(v, depth+1)]
                                    for k, v in islice(obj.items(), 100)]
                entry['length'] = len(obj)
            elif type(obj) is types.FunctionType:
                entry['name'] = obj.__name__
                entry['parameters'] = list(obj.__code__.co_varnames[:obj.__code__.co_argcount])
            elif type(obj) is type:
                entry['name'] = type.__getattribute__(obj, '__name__')
            else:
                # Do not run properties, custom repr or custom attribute access.
                attrs = {}
                for base in type.__getattribute__(type(obj), '__mro__'):
                    descriptor = type.__getattribute__(base, '__dict__').get('__dict__')
                    if descriptor is not None:
                        if type(descriptor) in (types.GetSetDescriptorType, types.MemberDescriptorType):
                            try:
                                attrs = descriptor.__get__(obj, type(obj))
                            except (AttributeError, TypeError):
                                pass
                        break
                if type(attrs) is dict:
                    entry['attributes'] = {k: value(v, depth+1) for k, v in islice(attrs.items(), 100)
                                           if type(k) is str}
            return ref

        result = []
        for frame_id, frame in frames:
            scope = {}
            for name, obj in list(frame.f_locals.items()):
                if name.startswith(('__', '_pyvis_observe_')) or type(obj) is types.ModuleType:
                    continue
                scope[name] = value(obj)
            result.append({'id': frame_id, 'name': frame.f_code.co_name,
                           'definition_line': frame.f_code.co_firstlineno,
                           'file': frame.f_code.co_filename, 'line': frame.f_lineno,
                           'locals': scope})
        extras = [value(obj) for obj in extra]
        return {'frames': result, 'heap': heap, 'values': extras}


class Output(io.TextIOBase):
    def __init__(self, recorder, channel):
        self.recorder, self.channel = recorder, channel

    def write(self, text):
        if text:
            self.recorder.output[self.channel] += text
            self.recorder.emit('output', text=text, channel=self.channel)
        return len(text)

    def flush(self):
        pass


class Recorder:
    def __init__(self, on_event=None, gate=None, input_provider=None, max_events=20000, *, retain_events=True):
        self.events = []
        self.event_count = 0
        self.retain_events = retain_events
        self.source_lines = {}
        self.encoded_lines = {}
        self.on_event, self.gate = on_event, gate
        self.input_provider = input_provider or (lambda prompt: '')
        self.max_events = max_events
        self.frames = []
        self.frame_counter = 0
        self.snapshot = Snapshot()
        self.output = {'stdout': '', 'stderr': ''}
        self.sources = {}
        self.source_errors = {}
        self.busy = False
        self.hook_name = '_pyvis_observe_' + uuid.uuid4().hex
        self.error = None
        self.pending = {}
        self.statements = {}
        self.expression_info = {}
        self.expression_operators = {}

    def emit(self, kind, frame=None, *, captured=None, **payload):
        if self.busy:
            return
        if self.event_count >= self.max_events:
            raise RecordingLimit('执行记录达到上限，请缩短循环或分段运行。')
        self.busy = True
        try:
            frame = frame or (self.frames[-1][1] if self.frames else None)
            values = payload.pop('_values', ())
            event = {'seq': self.event_count, 'kind': kind,
                     'file': frame.f_code.co_filename if frame else None,
                     'line': frame.f_lineno if frame else None,
                     **payload, **(captured if captured is not None else self.snapshot.capture(self.frames, values))}
            self.event_count += 1
            if self.retain_events:
                self.events.append(event)
            if self.on_event:
                self.on_event(event)
            return event
        finally:
            self.busy = False

    def observe(self, result, line, col, end_line, end_col, expression):
        # Evaluation happens in the caller before this callback.
        frame = sys._getframe(1)
        source_lines = self.encoded_lines[frame.f_code.co_filename]
        excerpt = ''
        if line == end_line and line <= len(source_lines):
            excerpt = source_lines[line-1][col:end_col].decode('utf-8')
        operands = []
        for child in self.expression_info.get((frame.f_code.co_filename, line, col, end_line, end_col), []):
            value = child.get('literal')
            pending = self.pending.get(id(frame), {})
            value = pending.get('operand_values', {}).get(tuple(child['span']), value)
            if value is not None:
                operands.append({'label': child['text'], 'value': value})
        event = self.emit('expression', frame, span=[line, col, end_line, end_col], operands=operands,
                  expression=expression, expression_text=excerpt,
                  operators=self.expression_operators.get((frame.f_code.co_filename, line, col, end_line, end_col), []),
                  _values=(result,))
        pending = self.pending.get(id(frame))
        if pending is not None and event is not None:
            pending['operations'].append(event['seq'])
            pending['operand_values'][(line, col, end_line, end_col)] = event['values'][0]
        return result

    def complete_statement(self, frame, outcome='completed', result=(), next_line=None, next_column=None):
        pending = self.pending.pop(id(frame), None)
        if pending is not None:
            body = pending.get('body_range')
            taken = None
            if (outcome == 'completed' and body and body[0] > pending['line']):
                if next_line is not None:
                    taken = body[0] <= next_line <= body[1]
                elif result:
                    # The frame returned before entering the multiline suite.
                    taken = False
            self.emit('statement', frame, line=pending['line'], column=pending['column'],
                      statement_type=pending['type'], code=pending['code'],
                      before=pending['before'], operation_seqs=pending['operations'],
                      outcome=outcome, start_seq=pending['start_seq'],
                      assigned_names=pending['assigned_names'],
                      body_range=body, condition_span=pending.get('condition_span'),
                      next_line=next_line, next_column=next_column, branch_taken=taken,
                      value_type=pending.get('value_type'), _values=result)

    def trace(self, frame, event, arg):
        if frame.f_code.co_filename not in self.sources:
            return None
        if event == 'call':
            self.frame_counter += 1
            self.frames.append((self.frame_counter, frame))
            self.emit('call', frame)
        elif event == 'line':
            info = self.statements.get((frame.f_code.co_filename, frame.f_lineno), {})
            line = info.get('line', frame.f_lineno)
            pending = self.pending.get(id(frame))
            # CPython reports physical lines inside a multiline expression,
            # including revisiting the opening line when constructing a dict.
            # They are one pending statement, not completed empty statements.
            # A repeated loop header still represents another condition check.
            if pending and pending['line'] == line:
                loop_header = info.get('type') in ('For', 'AsyncFor', 'While') and frame.f_lineno == line
                if not loop_header:
                    return self.trace
            self.complete_statement(frame, next_line=line, next_column=info.get('column'))
            before = self.snapshot.capture(self.frames)
            self.pending[id(frame)] = {
                'line': line, 'column': info.get('column'), 'type': info.get('type', 'Statement'),
                'code': info.get('code', self.source_lines[frame.f_code.co_filename][line-1].strip()),
                'before': before, 'operations': [], 'operand_values': {}, 'start_seq': self.event_count,
                'assigned_names': info.get('assigned_names', []),
                'body_range': info.get('body_range'),
                'condition_span': info.get('condition_span'),
                'value_type': info.get('value_type')}
            self.emit('line', frame, captured=before, line=line, column=info.get('column'))
            if self.gate:
                self.gate()
        elif event == 'return':
            self.complete_statement(frame, result=(arg,))
            self.emit('return', frame, _values=(arg,))
            self.frames = [(i, f) for i, f in self.frames if f is not frame]
        elif event == 'exception':
            self.complete_statement(frame, outcome='exception')
            self.emit('exception', frame, exception_type=type.__getattribute__(arg[0], '__name__'),
                      message=exception_message(arg[1]))
        return self.trace

    def run(self, entry, project=None):
        entry = Path(entry).resolve()
        project = Path(project or entry.parent).resolve()
        for folder, directories, filenames in os.walk(project):
            directories[:] = [name for name in directories
                              if not name.startswith('.') and name not in ('venv', 'node_modules', '__pycache__')]
            for name in filenames:
                if name.startswith('.') or not name.endswith('.py'):
                    continue
                self.load_source(Path(folder) / name)
        if str(entry) not in self.sources and str(entry) not in self.source_errors:
            self.load_source(entry)
        old_path, old_argv, old_cwd = sys.path[:], sys.argv[:], os.getcwd()
        old_trace = sys.gettrace()
        old_input = builtins.input
        old_hook = getattr(builtins, self.hook_name, None)
        # Local modules are loaded through the same transformer.
        import importlib.abc
        import importlib.util
        recorder = self

        class Loader(importlib.abc.Loader):
            def create_module(self, spec):
                return None
            def exec_module(self, module):
                exec(recorder.compile(module.__spec__.origin), module.__dict__)

        class Finder(importlib.abc.MetaPathFinder):
            def find_spec(self, fullname, path=None, target=None):
                parts = fullname.split('.')
                file = project.joinpath(*parts).with_suffix('.py')
                package = project.joinpath(*parts, '__init__.py')
                if str(package) in recorder.sources or str(package) in recorder.source_errors:
                    return importlib.util.spec_from_file_location(fullname, package, loader=Loader(), submodule_search_locations=[str(package.parent)])
                if str(file) in recorder.sources or str(file) in recorder.source_errors:
                    return importlib.util.spec_from_file_location(fullname, file, loader=Loader())
                return None

        finder = Finder()
        def read_input(prompt=''):
            self.emit('input_request', prompt=str(prompt))
            response = self.input_provider(str(prompt))
            self.emit('input', prompt=str(prompt), text=response)
            return response
        namespace = {'__name__': '__main__', '__file__': str(entry), '__builtins__': builtins}
        try:
            sys.path.insert(0, str(project))
            sys.argv = [str(entry)]
            os.chdir(project)
            sys.meta_path.insert(0, finder)
            setattr(builtins, self.hook_name, self.observe)
            builtins.input = read_input
            with contextlib.redirect_stdout(Output(self, 'stdout')), contextlib.redirect_stderr(Output(self, 'stderr')):
                code = self.compile(str(entry))
                sys.settrace(self.trace)
                exec(code, namespace)
        except BaseException as exc:
            name = type.__getattribute__(type(exc), '__name__')
            message = exception_message(exc)
            trace = traceback.format_tb(exc.__traceback__)
            self.error = {'type': name, 'message': message,
                          'traceback': 'Traceback (most recent call last):\n' + ''.join(trace) +
                          (f'{name}: {message}\n' if message else f'{name}\n')}
            if isinstance(exc, SyntaxError):
                self.error.update(file=exc.filename, line=exc.lineno, column=exc.offset)
            else:
                tb = exc.__traceback__
                while tb:
                    if tb.tb_frame.f_code.co_filename in self.sources:
                        self.error.update(file=tb.tb_frame.f_code.co_filename, line=tb.tb_lineno)
                    tb = tb.tb_next
        finally:
            sys.settrace(old_trace)
            builtins.input = old_input
            if old_hook is None:
                delattr(builtins, self.hook_name)
            else:
                setattr(builtins, self.hook_name, old_hook)
            sys.meta_path.remove(finder)
            sys.path[:], sys.argv[:] = old_path, old_argv
            os.chdir(old_cwd)
        return {'version': 1, 'python': sys.version, 'sources': self.sources,
                'events': self.events, 'output': self.output, 'error': self.error,
                'status': 'error' if self.error else 'completed'}

    def load_source(self, path):
        filename = str(path)
        try:
            text, _ = decode_source(path.read_bytes())
            source = text.replace('\r\n', '\n').replace('\r', '\n')
            self.sources[filename] = source
            self.source_lines[filename] = source.split('\n')
        except SyntaxError as error:
            self.source_errors[filename] = SyntaxError(error.msg, (filename, error.lineno or 1, error.offset or 1, None))
        except (OSError, UnicodeError, LookupError) as error:
            self.source_errors[filename] = SyntaxError(str(error), (filename, 1, 1, None))

    def compile(self, filename):
        if filename in self.source_errors:
            raise self.source_errors[filename]
        source = self.sources[filename]
        tree = ast.parse(source, filename=filename)
        source_lines = source.split('\n')
        encoded_lines = [line.encode('utf-8') for line in source_lines]
        self.encoded_lines[filename] = encoded_lines

        def segment(node):
            start, end = node.lineno - 1, node.end_lineno - 1
            if start == end:
                return encoded_lines[start][node.col_offset:node.end_col_offset].decode('utf-8')
            lines = [encoded_lines[start][node.col_offset:], *encoded_lines[start+1:end],
                     encoded_lines[end][:node.end_col_offset]]
            return b'\n'.join(lines).decode('utf-8')

        control_tests = set()

        def keep_jump_context(test):
            if isinstance(test, ast.BoolOp):
                control_tests.add(test)
                for value in test.values:
                    keep_jump_context(value)
            elif isinstance(test, ast.UnaryOp) and isinstance(test.op, ast.Not):
                control_tests.add(test)
                keep_jump_context(test.operand)
            elif isinstance(test, ast.Compare) and len(test.ops) > 1:
                control_tests.add(test)
            elif isinstance(test, ast.IfExp):
                keep_jump_context(test.body)
                keep_jump_context(test.orelse)

        for node in ast.walk(tree):
            if isinstance(node, (ast.If, ast.While, ast.IfExp, ast.Assert)):
                keep_jump_context(node.test)
            elif isinstance(node, ast.comprehension):
                for test in node.ifs:
                    keep_jump_context(test)
            elif isinstance(node, ast.match_case) and node.guard is not None:
                keep_jump_context(node.guard)
            if isinstance(node, (ast.BinOp, ast.UnaryOp, ast.BoolOp, ast.Compare)):
                operators = node.ops if isinstance(node, ast.Compare) else [node.op]
                self.expression_operators[(filename, node.lineno, node.col_offset, node.end_lineno, node.end_col_offset)] = [type(op).__name__ for op in operators]
            children = []
            if isinstance(node, ast.BinOp): children = [node.left, node.right]
            elif isinstance(node, ast.UnaryOp): children = [node.operand]
            elif isinstance(node, ast.Compare): children = [node.left, *node.comparators]
            elif isinstance(node, ast.Call): children = [*node.args, *(item.value for item in node.keywords)]
            if children:
                info = []
                for child in children:
                    item = {'span': [child.lineno, child.col_offset, child.end_lineno, child.end_col_offset], 'text': segment(child)}
                    if isinstance(child, ast.Constant) and type(child.value) in (int, float, str, bool, type(None)):
                        literal = child.value
                        if type(literal) is float and (literal != literal or abs(literal) == float('inf')):
                            literal = str(literal)
                        item['literal'] = {'type': type(child.value).__name__, 'value': literal}
                    info.append(item)
                self.expression_info[(filename, node.lineno, node.col_offset, node.end_lineno, node.end_col_offset)] = info
            if isinstance(node, ast.stmt):
                targets = node.targets if isinstance(node, ast.Assign) else ([node.target] if isinstance(node, (ast.AnnAssign, ast.AugAssign, ast.For)) else [])
                names = [part.id for target in targets for part in ast.walk(target)
                         if isinstance(part, ast.Name) and isinstance(part.ctx, ast.Store)]
                info = {'type': type(node).__name__, 'assigned_names': names,
                        'line': node.lineno, 'column': node.col_offset, 'code': segment(node)}
                if isinstance(node, (ast.If, ast.While, ast.For, ast.AsyncFor)):
                    info['body_range'] = [node.body[0].lineno, node.body[-1].end_lineno]
                if isinstance(node, (ast.Assign, ast.AnnAssign)) and node.value is not None:
                    info['value_type'] = type(node.value).__name__
                if isinstance(node, (ast.If, ast.While)):
                    test = node.test
                    info['condition_span'] = [test.lineno, test.col_offset, test.end_lineno, test.end_col_offset]
                # Map continuation lines to their owning statement. Compound
                # statements own only the header; bodies keep their own records.
                body = getattr(node, 'body', None)
                end = max(node.lineno, body[0].lineno - 1) if isinstance(body, list) and body else node.end_lineno
                if isinstance(body, list) and body:
                    info['code'] = source_lines[node.lineno-1].strip()
                for line in range(node.lineno, end + 1):
                    self.statements.setdefault((filename, line), info)
        tree = Instrument(self.hook_name, control_tests).visit(tree)
        ast.fix_missing_locations(tree)
        return compile(tree, filename, 'exec', dont_inherit=True)
