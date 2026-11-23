import ast
from pathlib import Path
import time
import unittest

from pyvis_runtime import Recorder
from pyvis_runtime.blueprint import code_graph

FIXTURE = Path(__file__).parent / 'fixtures' / 'menu_decimal.py'


class CompoundGraphTests(unittest.TestCase):
    def test_actual_menu_expands_every_statement_without_unsupported_blocks(self):
        source = FIXTURE.read_text()
        started = time.perf_counter()
        graph = code_graph(source)
        self.assertLess(time.perf_counter() - started, 2)
        self.assertEqual(graph['warnings'], [])
        self.assertGreater(len(graph['nodes']), 800)
        self.assertFalse(any(n['kind'] == 'unsupported' for n in graph['nodes']))
        statements = {n['statement_id'] for n in graph['nodes']}
        for stmt in ast.walk(ast.parse(source)):
            if isinstance(stmt, ast.stmt):
                self.assertIn(f'main:{stmt.lineno}:{stmt.col_offset}:{type(stmt).__name__}', statements)
        self.assertTrue({'try', 'exception', 'context_enter', 'context_exit', 'format', 'import'} <=
                        {n['kind'] for n in graph['nodes']})

    def test_large_menu_regions_are_local_non_overlapping_and_all_nodes_survive(self):
        graph = code_graph(FIXTURE.read_text())
        view = graph['whole_views'][0]
        self.assertTrue(view['detailed'])
        self.assertGreater(len(view['sections']), 50)
        self.assertEqual({n['id'] for n in graph['nodes']},
                         {n['id'] for n in view['nodes'] if n['kind'] != 'reference'})
        self.assertTrue(all('section_id' in n for n in view['nodes']))
        self.assertLess(view['width'], 1800)
        for left, right in zip(view['sections'], view['sections'][1:]):
            self.assertLess(left['y'] + left['height'], right['y'])
        for i, a in enumerate(view['nodes']):
            for b in view['nodes'][i+1:]:
                self.assertFalse(a['x'] < b['x'] + b['width'] and b['x'] < a['x'] + a['width'] and
                                 a['y'] < b['y'] + b['height'] and b['y'] < a['y'] + a['height'], (a['id'], b['id']))
        self.assertTrue(any(l['kind'] == 'exception' for l in view['section_links']))
        self.assertTrue(any(l['label'] == '下一轮' for l in view['section_links']))
        self.assertTrue(any(s['path'] for s in view['sections']))

    def test_exception_handlers_match_in_order_and_else_is_normal_only(self):
        graph = code_graph('try:\n    x=f()\nexcept ValueError:\n    y=1\nexcept TypeError:\n    y=2\nelse:\n    y=3\nprint(y)\n')
        nodes = {n['id']: n for n in graph['nodes']}
        value_check = next(n for n in graph['nodes'] if n.get('exception_type') == 'ValueError')
        type_check = next(n for n in graph['nodes'] if n.get('exception_type') == 'TypeError')
        self.assertTrue(any(e['from'] == value_check['id'] and e['to'] == type_check['id'] and
                            '不匹配' in e['label'] for e in graph['edges']))
        handlers = {n['id'] for n in graph['nodes'] if n['kind'] == 'branch' and n['title'] == '处理这个异常'}
        self.assertTrue(all(e['kind'] == 'guard' and nodes[e['from']]['kind'] == 'exception'
                            for e in graph['edges'] if e['to'] in handlers))
        else_write = next(n for n in graph['nodes'] if n['kind'] == 'write' and n['line'] == 8)
        incoming = [e for e in graph['edges'] if e['to'] == else_write['id'] and e['kind'] == 'flow']
        self.assertTrue(incoming)
        self.assertEqual({nodes[e['from']]['line'] for e in incoming}, {2})
        self.assertTrue(any(e['kind'] == 'exception' and nodes[e['from']]['kind'] == 'call' for e in graph['edges']))

    def test_finally_runs_before_return_and_before_break_but_not_inner_loop_break(self):
        graph = code_graph('def f():\n    try:\n        return 1\n    finally:\n        print("done")\n')
        pending = next(n for n in graph['nodes'] if n['kind'] == 'pending_return')
        cleanup = next(n for n in graph['nodes'] if n['kind'] == 'finally')
        returned = next(n for n in graph['nodes'] if n['kind'] == 'return')
        self.assertTrue(any(e['from'] == pending['id'] and e['to'] == cleanup['id'] for e in graph['edges']))
        self.assertNotEqual(pending['id'], returned['id'])
        graph = code_graph('while flag:\n    try:\n        break\n    finally:\n        cleanup()\n')
        stopped = next(n for n in graph['nodes'] if n['title'] == '跳出循环')
        target = next(n for n in graph['nodes'] if n['kind'] == 'finally')
        self.assertTrue(any(e['from'] == stopped['id'] and e['to'] == target['id'] for e in graph['edges']))
        graph = code_graph('try:\n    while flag:\n        break\nfinally:\n    cleanup()\n')
        stopped = next(n for n in graph['nodes'] if n['title'] == '跳出循环')
        target = next(n for n in graph['nodes'] if n['title'] == '离开循环')
        self.assertTrue(any(e['from'] == stopped['id'] and e['to'] == target['id'] for e in graph['edges']))

    def test_with_enters_in_order_exits_in_reverse_and_tests_exception_suppression(self):
        graph = code_graph('with first() as a, second() as b:\n    x = f(a,b)\nprint(x)\n')
        nodes = {n['id']: n for n in graph['nodes']}
        entries = [n for n in graph['nodes'] if n['kind'] == 'context_enter']
        exits = [n for n in graph['nodes'] if n['kind'] == 'context_exit']
        self.assertEqual(len(entries), 2)
        self.assertEqual(len(exits), 2)
        self.assertTrue(any(e['from'] == exits[1]['id'] and e['to'] == exits[0]['id'] and e['kind'] == 'exception' for e in graph['edges']) or
                        any(nodes[e['from']]['kind'] == 'condition' and e['to'] == exits[0]['id'] and e['kind'] == 'flow' for e in graph['edges']))
        checks = [n for n in graph['nodes'] if n['title'] == '上下文是否处理了异常']
        self.assertEqual(len(checks), 2)
        self.assertTrue(all(any(e['to'] == n['id'] and e['kind'] == 'guard' for e in graph['edges']) for n in checks))
        graph = code_graph('with manager() as target.attr:\n    work()\n')
        assignment = next(n for n in graph['nodes'] if n['kind'] == 'write')
        gate = next(n for n in graph['nodes'] if n['title'] == '携带异常退出上下文')
        self.assertTrue(any(e['from'] == assignment['id'] and e['to'] == gate['id'] and e['kind'] == 'exception' for e in graph['edges']))

    def test_f_strings_formats_and_import_aliases_are_separate_nodes(self):
        graph = code_graph('from decimal import Decimal as D\nx=D(2)\nprint(f"值={x!r:>{width}}")\n')
        self.assertEqual(graph['warnings'], [])
        alias = next(n for n in graph['nodes'] if n['kind'] == 'symbol' and n['title'] == 'D')
        read = next(n for n in graph['nodes'] if n['kind'] == 'read' and n.get('symbol') == 'D')
        self.assertTrue(any(e['from'] == alias['id'] and e['to'] == read['id'] for e in graph['edges']))
        self.assertTrue(any(n['kind'] == 'format' and n['title'] == '格式化!r' for n in graph['nodes']))
        self.assertTrue(any(n['kind'] == 'read' and n.get('symbol') == 'width' for n in graph['nodes']))
        self.assertTrue(any(n['kind'] == 'construct' and n['title'] == '拼接文本' for n in graph['nodes']))

    def test_function_definition_does_not_inherit_callers_exception_or_cleanup_context(self):
        graph = code_graph('try:\n    def f():\n        return broken()\n    x=f()\nfinally:\n    close()\n')
        nodes = {n['id']: n for n in graph['nodes']}
        self.assertTrue(any(n['kind'] == 'return' and n['scope'] != 'main' for n in graph['nodes']))
        self.assertFalse(any(e['kind'] == 'exception' and nodes[e['from']]['scope'] != nodes[e['to']]['scope'] for e in graph['edges']))

    def test_loop_slots_only_keep_values_needed_between_iterations_or_after_loop(self):
        graph = code_graph('while True:\n    choice=input()\n    print(choice)\n    if choice=="q":\n        break\n')
        self.assertFalse(any(n['kind'] == 'variable' and n.get('symbol') == 'choice' for n in graph['nodes']))
        graph = code_graph('i=0\nwhile i<4:\n    if flag:\n        i=i+1\n    else:\n        i=i+2\nprint(i)\n')
        slot = next(n for n in graph['nodes'] if n['title'] == '循环中的 i')
        merge = next(n for n in graph['nodes'] if n['title'] == 'i：使用所选分支的值')
        self.assertTrue(any(e['from'] == merge['id'] and e['to'] == slot['id'] and e['label'] == '下一轮的值' for e in graph['edges']))

    def test_menu_real_python_math_and_decimal_errors_still_run(self):
        for inputs, expected in [(['b', 'c', 'd', 'q'], ['1275', '120', '第5次', '程序已退出']),
                                 (['a', '1', 'NaN', 'bad', '2.5', '0', 'q', 'q'], ['输入无效', '最终总和为：2.5']),
                                 (['a', '2', '1 2.5 3', 'q', 'q', 'q'], ['总和为：6.5']),
                                 ([], ['输入已结束，程序退出'])]:
            with self.subTest(inputs=inputs):
                answers = iter(inputs)
                def answer(_):
                    try: return next(answers)
                    except StopIteration: raise EOFError
                result = Recorder(input_provider=answer).run(FIXTURE)
                self.assertIsNone(result['error'])
                for text in expected: self.assertIn(text, result['output']['stdout'])
