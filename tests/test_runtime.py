import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from pyvis_runtime import Recorder
from pyvis_runtime.engine import Output


class RuntimeTests(unittest.TestCase):
    def test_streamed_recording_matches_archive_without_retaining_history(self):
        with tempfile.TemporaryDirectory() as folder:
            entry = Path(folder) / 'example.py'
            entry.write_text('def f(n):\n    return (n + 2) * 3\nx = f(4) + f(5)\nprint(x)\n')
            archive = Recorder().run(entry)
            emitted = []
            streaming = Recorder(on_event=emitted.append, retain_events=False)
            summary = streaming.run(entry)
            self.assertEqual(summary['events'], [])
            self.assertEqual(emitted, archive['events'])
            self.assertEqual(summary['output'], archive['output'])
            self.assertEqual(streaming.event_count, len(emitted))

    def run_code(self, source, **kwargs):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'main.py'
            path.write_text(source, encoding='utf-8')
            return Recorder(**kwargs).run(path)

    def test_output_keeps_channels_and_order_without_capturing(self):
        recorder = Recorder(max_events=1)
        with patch.object(recorder.snapshot, 'capture', side_effect=AssertionError('unexpected snapshot')):
            stdout, stderr = Output(recorder, 'stdout'), Output(recorder, 'stderr')
            self.assertEqual(stdout.write('a'), 1)
            stdout.flush()
            stderr.write('好')
            stdout.write('\n')
        self.assertEqual(recorder.output, {'stdout': 'a\n', 'stderr': '好'})
        self.assertEqual([(e['channel'], e['text']) for e in recorder.events],
                         [('stdout', 'a'), ('stderr', '好'), ('stdout', '\n')])
        self.assertEqual([e['seq'] for e in recorder.events], [0, 1, 2])
        for event in recorder.events:
            self.assertEqual((event['frames'], event['heap'], event['values']), ([], {}, []))

    def test_output_limit_keeps_complete_utf8_characters_and_execution_continues(self):
        result = self.run_code(
            "import sys\nsys.stdout.write('A')\n"
            "count = sys.stderr.write('好😀!')\n"
            "sys.stdout.write('later')\ncontinued = count + 40\n",
            max_output_bytes=7,
        )
        self.assertIsNone(result['error'])
        self.assertTrue(result['output_truncated'])
        self.assertEqual(result['output'], {'stdout': 'A', 'stderr': '好'})
        output = [e for e in result['events'] if e['kind'] == 'output']
        self.assertEqual([(e['channel'], e['text']) for e in output],
                         [('stdout', 'A'), ('stderr', '好')])
        self.assertEqual([e.get('output_truncated', False) for e in output], [False, True])
        self.assertEqual(result['events'][-1]['frames'][-1]['locals']['continued']['value'], 43)
        self.assertEqual([e['seq'] for e in result['events']], list(range(len(result['events']))))

    def test_fragment_limit_reports_once_without_using_the_execution_budget(self):
        recorder = Recorder(max_events=1, max_output_events=2)
        stream = Output(recorder, 'stdout')
        for part in ('a', 'b', 'c', 'd'):
            self.assertEqual(stream.write(part), 1)
        self.assertEqual(recorder.output['stdout'], 'ab')
        self.assertEqual([e['text'] for e in recorder.events], ['a', 'b', ''])
        self.assertEqual(sum(e.get('output_truncated', False) for e in recorder.events), 1)
        self.assertEqual(recorder.emit('line')['seq'], 3)

    def test_side_effects_and_short_circuit(self):
        result = self.run_code('''calls = []
def f(x):
    calls.append(x)
    return x
x = f(2) + f(3)
y = False and f(9)
z = 0 < f(4) < 10
print(x, y, z, calls)
''')
        self.assertIsNone(result['error'])
        self.assertEqual(result['output']['stdout'], '5 False True [2, 3, 4]\n')

    def test_instrumentation_preserves_patterns_and_future_annotations(self):
        result = self.run_code('''from __future__ import annotations
from enum import Enum
class Color(Enum):
    RED = 1
def name(value: list[int]) -> str:
    match value:
        case [Color.RED]:
            return 'red'
print(name([Color.RED]), name.__annotations__)
''')
        self.assertIsNone(result['error'])
        self.assertEqual(result['output']['stdout'],
                         "red {'value': 'list[int]', 'return': 'str'}\n")

    def test_exception_recording_never_calls_user_string_formatter(self):
        result = self.run_code('''class CustomError(Exception):
    def __str__(self):
        raise ValueError('called __str__')
try:
    raise CustomError('message')
except CustomError:
    print('caught')
''')
        self.assertIsNone(result['error'])
        self.assertEqual(result['output']['stdout'], 'caught\n')

    def test_recording_does_not_keep_weakly_referenced_objects_alive(self):
        result = self.run_code('''import weakref
class Box:
    pass
box = Box()
ref = weakref.ref(box)
del box
print(ref() is None)
''')
        self.assertIsNone(result['error'])
        self.assertEqual(result['output']['stdout'], 'True\n')

    def test_unreadable_source_is_reported_only_when_used(self):
        with tempfile.TemporaryDirectory() as folder:
            entry = Path(folder) / 'main.py'
            broken = entry.with_name('broken.py')
            broken.write_bytes(b'\xff')
            entry.write_text("print('ok')\n")
            self.assertEqual(Recorder().run(entry)['output']['stdout'], 'ok\n')
            entry.write_text('import broken\n')
            self.assertEqual(Recorder().run(entry)['error']['file'], str(broken.resolve()))

    def test_snapshot_budget_preserves_resolvable_references(self):
        from pyvis_runtime.engine import Snapshot

        root = [[[] for _ in range(100)] for _ in range(100)]
        heap = Snapshot().capture([], (root,))['heap']
        self.assertEqual(len(heap), 500)
        self.assertTrue(all(item['ref'] in heap for obj in heap.values()
                            for item in obj.get('items', []) if 'ref' in item))

    def test_recorded_branch_direction_does_not_test_a_value_twice(self):
        result = self.run_code('''class Value:
    def __bool__(self):
        print("checked")
        return False
value = Value()
if value and 10 > 0:
    print("unreachable")
else:
    print("else")
while 1 < 0:
    print("unreachable")
print("end")
''')
        self.assertIsNone(result['error'])
        self.assertEqual(result['output']['stdout'], 'checked\nelse\nend\n')
        decisions = [e for e in result['events'] if e.get('statement_type') in ('If', 'While')]
        self.assertEqual([(e['line'], e['branch_taken'], e['next_line']) for e in decisions],
                         [(6, False, 9), (10, False, 12)])
        self.assertTrue(all(e['condition_span'] is not None for e in decisions))

    def test_assignment_targets_are_independent_of_other_changed_locals(self):
        result = self.run_code('a=1\ndef change():\n    global a\n    a=5\n    return 2\nx=a+change()+a\nx=x\n')
        assignments = [e for e in result['events'] if e['kind'] == 'statement' and e['line'] in (6, 7)]
        self.assertEqual([e['assigned_names'] for e in assignments], [['x'], ['x']])
        self.assertEqual(assignments[0]['frames'][0]['locals']['x']['value'], 8)

    def test_for_targets_and_body_are_recorded_even_for_equal_elements(self):
        result = self.run_code('for item in [1, 1]:\n    value = item\nprint(value)\n')
        iterations = [e for e in result['events']
                      if e['kind'] == 'statement' and e['statement_type'] == 'For']
        self.assertEqual(len(iterations), 3)
        self.assertEqual([e['assigned_names'] for e in iterations], [['item']] * 3)
        self.assertEqual([e['body_range'] for e in iterations], [[2, 2]] * 3)
        self.assertEqual([e['frames'][-1]['line'] for e in iterations], [2, 2, 3])
        self.assertEqual([e['frames'][-1]['locals']['item']['value']
                          for e in iterations], [1, 1, 1])
        self.assertEqual(result['output']['stdout'], '1\n')

    def test_multiline_dictionary_is_one_completed_assignment(self):
        source = 'inventory = {\n    "pen": {"price": 20, "stock": 12},\n    "bag": {"price": 35, "stock": 8},\n}\nprint(inventory["pen"]["stock"])\n'
        result = self.run_code(source)
        statements = [e for e in result['events'] if e['kind'] == 'statement']
        self.assertEqual([e['line'] for e in statements], [1, 5])
        self.assertEqual(statements[0]['assigned_names'], ['inventory'])
        self.assertNotIn('inventory', statements[0]['before']['frames'][-1]['locals'])
        self.assertIn('inventory', statements[0]['frames'][-1]['locals'])
        self.assertEqual(result['output']['stdout'], '12\n')

    def test_multiline_call_and_condition_keep_body_and_repeated_loop_checks(self):
        source = 'def add(a, b):\n    return a+b\nx=add(\n    2,\n    3,\n)\nwhile (\n    x < 7\n):\n    x+=1\nprint(x)\n'
        result = self.run_code(source)
        statements = [e for e in result['events'] if e['kind'] == 'statement']
        self.assertEqual(result['output']['stdout'], '7\n')
        self.assertEqual([e['line'] for e in statements if e['statement_type'] == 'While'], [7, 7, 7])
        self.assertEqual([e['line'] for e in statements if e['statement_type'] == 'AugAssign'], [10, 10])
        assigned = [e for e in statements if e['statement_type'] == 'Assign']
        self.assertEqual([e['line'] for e in assigned], [3])
        self.assertEqual(assigned[0]['frames'][-1]['locals']['x']['value'], 5)

    def test_alias_and_immutable_history(self):
        result = self.run_code('a = [1]\nb = a\nb.append(2)\nprint(a)\n')
        events = result['events']
        before = next(e for e in events if e['kind'] == 'line' and e['line'] == 3)
        after = next(e for e in events if e['kind'] == 'line' and e['line'] == 4)
        scope = after['frames'][0]['locals']
        self.assertEqual(scope['a']['ref'], scope['b']['ref'])
        oid = scope['a']['ref']
        self.assertEqual(len(before['heap'][oid]['items']), 1)
        self.assertEqual(len(after['heap'][oid]['items']), 2)
        json.dumps(result, allow_nan=False)

    def test_recursion_frames(self):
        result = self.run_code('''def fact(n):
    if n <= 1:
        return 1
    return n * fact(n-1)
answer = fact(5)
print(answer)
''')
        self.assertEqual(result['output']['stdout'], '120\n')
        deepest = max(result['events'], key=lambda e: len(e['frames']))
        values = [f['locals']['n']['value'] for f in deepest['frames'] if 'n' in f['locals']]
        self.assertEqual(values, [5, 4, 3, 2, 1])
        self.assertEqual(len(set(f['id'] for f in deepest['frames'])), 6)

    def test_cycles_and_custom_repr(self):
        result = self.run_code('''class Box:
    def __repr__(self):
        raise RuntimeError('must not run')
a = []
a.append(a)
b = Box()
b.items = a
print(len(a))
''')
        self.assertIsNone(result['error'])
        json.dumps(result)

    def test_classes_and_super(self):
        result = self.run_code('''class Base:
    def value(self):
        return 7
class Child(Base):
    def value(self):
        return super().value() + 1
c = Child()
print(c.value())
''')
        self.assertIsNone(result['error'])
        self.assertEqual(result['output']['stdout'], '8\n')

    def test_errors_keep_prior_events(self):
        result = self.run_code('values = [1]\nprint(values[4])\n')
        self.assertEqual(result['error']['type'], 'IndexError')
        self.assertEqual(result['error']['line'], 2)
        self.assertTrue(result['events'])
        syntax = self.run_code('if True\n    pass\n')
        self.assertEqual(syntax['error']['type'], 'SyntaxError')
        self.assertEqual(syntax['error']['line'], 1)

    def test_input_and_recording_limit(self):
        result = self.run_code('name = input("名字：")\nprint(name)\n', input_provider=lambda _: '小林')
        self.assertEqual(result['output']['stdout'], '小林\n')
        self.assertTrue(any(e['kind'] == 'input' for e in result['events']))
        result = self.run_code('while True:\n    pass\n', max_events=20)
        self.assertEqual(result['error']['type'], 'RecordingLimit')
        self.assertEqual(len(result['events']), 20)

    def test_inspection_does_not_trigger_descriptors(self):
        result = self.run_code("""class Box:
    @property
    def __dict__(self):
        raise RuntimeError('inspection executed property')
    def __getattribute__(self, name):
        if name == '__class__':
            raise RuntimeError('inspection read class')
        return object.__getattribute__(self, name)
b = Box()
print('ok')
""")
        self.assertIsNone(result['error'])
        self.assertEqual(result['output']['stdout'], 'ok\n')

    def test_semantics_against_unmodified_cpython(self):
        source = """calls = []
class Truth:
    def __bool__(self):
        calls.append('bool')
        return False
def take(x):
    calls.append(x)
    return x
x = Truth()
a = x and take(9)
b = take(2) < take(3) < take(4)
values = [1, 2]
alias = values
alias += [3]
print(calls, b, values, values is alias)
"""
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'main.py'
            path.write_text(source)
            baseline = subprocess.run([sys.executable, str(path)], capture_output=True, text=True, check=True)
            result = Recorder().run(path)
        self.assertIsNone(result['error'])
        self.assertEqual(result['output']['stdout'], baseline.stdout)

    def test_each_executed_line_has_graphical_effect(self):
        result = self.run_code('a = 2\nb = 3\nc = a + b\nif c > 4:\n    items = [c]\nitems.append(8)\n')
        statements = [e for e in result['events'] if e['kind'] == 'statement']
        self.assertEqual([e['line'] for e in statements], [1, 2, 3, 4, 5, 6])
        calculation = statements[2]
        self.assertNotIn('c', calculation['before']['frames'][0]['locals'])
        self.assertEqual(calculation['frames'][0]['locals']['c']['value'], 5)
        operations = [result['events'][i] for i in calculation['operation_seqs']]
        self.assertEqual([e['expression_text'] for e in operations], ['a', 'b', 'a + b'])
        self.assertEqual([e['values'][0]['value'] for e in operations], [2, 3, 5])
        mutation = statements[-1]
        oid = mutation['frames'][0]['locals']['items']['ref']
        self.assertEqual(len(mutation['before']['heap'][oid]['items']), 1)
        self.assertEqual(len(mutation['heap'][oid]['items']), 2)

    def test_infinite_float_operands_remain_serializable(self):
        result = self.run_code('x = 1e999 + 2\nprint(x)\n')
        self.assertIsNone(result['error'])
        self.assertEqual(result['output']['stdout'], 'inf\n')
        json.dumps(result, allow_nan=False)

    def test_local_module(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path/'calc_unique_pyvis.py').write_text('def double(x):\n    return x*2\n')
            (path/'main.py').write_text('from calc_unique_pyvis import double\nprint(double(4))\n')
            result = Recorder().run(path/'main.py')
            sys.modules.pop('calc_unique_pyvis', None)
        self.assertEqual(result['output']['stdout'], '8\n')
        self.assertTrue(any(e['file'].endswith('calc_unique_pyvis.py') for e in result['events']))

    def test_recording_reads_only_executed_project_imports(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            package = root / 'pyvis_recording_package'
            package.mkdir()
            entry = root / 'main.py'
            init = package / '__init__.py'
            helper = package / 'helper.py'
            peer = package / 'peer.py'
            entry.write_text('from pyvis_recording_package import value\nprint(value)\n')
            init.write_text('from .helper import value\n')
            helper.write_text('from . import peer\nvalue = peer.value + 1\n')
            peer.write_text('from . import helper\nvalue = 2\n')
            (package / 'unused.py').write_text('unused = 42\n')
            reads, wire = [], []
            read_bytes = Path.read_bytes

            def record_read(path):
                reads.append(path)
                return read_bytes(path)

            try:
                with patch.object(Path, 'read_bytes', record_read):
                    result = Recorder(on_event=wire.append, on_source=lambda file, _: wire.append(file)).run(entry)
            finally:
                for name in ('', '.helper', '.peer'):
                    sys.modules.pop(package.name + name, None)

            expected = [entry, init, helper, peer]
            self.assertEqual(reads, expected)
            self.assertEqual(list(result['sources']), list(map(str, expected)))
            self.assertEqual(result['output']['stdout'], '3\n')
            seen = set()
            for item in wire:
                if isinstance(item, str):
                    seen.add(item)
                elif item['file'] is not None:
                    self.assertIn(item['file'], seen)


if __name__ == '__main__':
    unittest.main()
