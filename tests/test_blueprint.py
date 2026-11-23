import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from pyvis_runtime.blueprint import code_graph


class BlueprintTests(unittest.TestCase):
    def test_mobile_views_match_full_graph(self):
        source = 'def twice(n):\n    return n * 2\nvalue = twice(5)\n'
        full = code_graph(source)
        self.assertEqual(code_graph(source, 'overview'), {'reading': full['reading']})
        nodes = code_graph(source, 'nodes')
        for key in ('whole_views', 'line_views', 'scopes', 'collections'):
            self.assertEqual(nodes[key], full[key])
        self.assertNotIn('reading', nodes)
        self.assertEqual(nodes['edges'], [e for e in full['edges'] if e['kind'] == 'call'])
        self.assertEqual({n['id'] for n in nodes['nodes']}, {e['to'] for e in nodes['edges']})

    def test_nested_expression_is_fine_grained_and_ordered_by_dependencies(self):
        graph = code_graph('c = a + b * 2\n')
        nodes = graph['nodes']
        lookup = {n['id']: n for n in nodes}
        multiply = next(n for n in nodes if n['kind'] == 'operator' and n['title'] == '×')
        plus = next(n for n in nodes if n['kind'] == 'operator' and n['title'] == '+')
        result = next(n for n in nodes if n.get('operation') == multiply['id'])
        self.assertEqual(result['kind'], 'value')
        self.assertTrue(any(e['from'] == result['id'] and e['to'] == plus['id'] for e in graph['edges']))
        assignment = next(n for n in nodes if n['kind'] == 'write' and n['symbol'] == 'c')
        variable = next(n for n in nodes if n['kind'] == 'symbol' and n['title'] == 'c')
        self.assertNotEqual(assignment['id'], variable['id'])
        self.assertTrue(any(e['from'] == assignment['id'] and e['to'] == variable['id'] for e in graph['edges']))
        self.assertTrue(all(lookup[e['from']]['x'] < lookup[e['to']]['x'] for e in graph['edges'] if e['kind'] in ('data', 'binding')))

    def test_variable_values_connect_across_lines_and_merge_by_selected_branch(self):
        graph = code_graph('a=2\nif flag:\n    b=a+1\nelse:\n    b=a-1\nc=b*2\n')
        nodes = {n['id']: n for n in graph['nodes']}
        references = [e for e in graph['edges'] if e['kind'] == 'binding']
        self.assertTrue(any(nodes[e['from']]['kind'] == 'symbol' and nodes[e['from']]['title'] == 'a' and nodes[e['to']]['kind'] == 'read' and nodes[e['to']].get('symbol') == 'a' for e in references))
        merged = next(n for n in graph['nodes'] if n['title'] == 'b：使用所选分支的值')
        incoming = [e for e in references if e['to'] == merged['id']]
        self.assertEqual({e['label'] for e in incoming}, {'成立时', '不成立时'})
        self.assertTrue(any(e['from'] == merged['id'] and nodes[e['to']]['kind'] == 'read' and nodes[e['to']].get('symbol') == 'b' for e in references))

    def test_loop_variables_have_initial_values_and_feedback_for_later_iterations(self):
        graph = code_graph('i=0\nwhile i<3:\n    i=i+1\nprint(i)\n')
        slot = next(n for n in graph['nodes'] if n['title'] == '循环中的 i')
        updates = [e for e in graph['edges'] if e['to'] == slot['id'] and e['kind'] == 'binding']
        self.assertEqual({e['label'] for e in updates}, {'初始值', '下一轮的值'})

    def test_small_program_layout_fits_one_view_without_overlapping_nodes(self):
        graph = code_graph('a=10\nb=12\nc=a+b\n')
        scope = graph['scopes'][0]
        self.assertLessEqual(scope['width'], 1200)
        self.assertLessEqual(scope['height'], 400)
        nodes = {n['id']: n for n in graph['nodes']}
        for edge in graph['edges']:
            if edge['kind'] in ('data', 'binding'):
                self.assertLess(nodes[edge['from']]['x'], nodes[edge['to']]['x'])
        for i, a in enumerate(graph['nodes']):
            for b in graph['nodes'][i+1:]:
                overlaps = a['x'] < b['x'] + b['width'] and b['x'] < a['x'] + a['width'] and a['y'] < b['y'] + b['height'] and b['y'] < a['y'] + a['height']
                self.assertFalse(overlaps, (a['title'], b['title']))

    def test_line_view_keeps_inputs_without_repeating_their_previous_assignments(self):
        graph = code_graph('a=10\nb=12\nc=a+b\n')
        view = next(v for v in graph['line_views'] if v['line'] == 3)
        self.assertEqual(view['code'], 'c=a+b')
        context = [n for n in view['nodes'] if n['context']]
        self.assertEqual({(n['title'], n['line']) for n in context}, {('a', 1), ('b', 2)})
        self.assertTrue(all(n['kind'] == 'symbol' for n in context))
        self.assertFalse(any(n['title'] in ('10', '12') for n in view['nodes']))
        self.assertEqual(sum(n['kind'] == 'read' for n in view['nodes']), 2)
        self.assertEqual(sum(n['kind'] == 'write' for n in view['nodes']), 1)
        ids = {n['id'] for n in view['nodes']}
        self.assertTrue(all(e['from'] in ids and e['to'] in ids for e in view['edges']))
        self.assertLessEqual(view['width'], 950)

    def test_branch_routes_do_not_run_both_arms(self):
        graph = code_graph('if x > 2:\n    y=1\nelse:\n    y=0\nprint(y)\n')
        lookup = {n['id']: n for n in graph['nodes']}
        decision = next(n for n in graph['nodes'] if n['title'] == '条件选路')
        paths = [e for e in graph['edges'] if e['from'] == decision['id'] and e['kind'] == 'guard']
        self.assertEqual({e['label'] for e in paths}, {'成立', '不成立'})
        self.assertEqual({lookup[e['to']]['kind'] for e in paths}, {'branch'})
        targets = {e['to'] for e in paths}
        self.assertEqual({lookup[e['to']]['line'] for e in graph['edges'] if e['from'] in targets and e['kind'] == 'flow'}, {2, 4})

    def test_loop_exit_and_continue_are_explicit(self):
        graph = code_graph('for x in values:\n    if x<0:\n        continue\n    print(x)\nelse:\n    print("done")\n')
        lookup = {n['id']: n for n in graph['nodes']}
        jumps = [e for e in graph['edges'] if e['label'] == '跳转']
        self.assertEqual(lookup[jumps[0]['to']]['title'], '取下一个元素')
        self.assertTrue(any(e['label'] == '结束' for e in graph['edges']))

    def test_recursion_has_parameter_internal_math_and_finite_call_return_edges(self):
        graph = code_graph('def f(n):\n    if n<=1:\n        return 1\n    return n*f(n-1)\nx=f(5)\n')
        self.assertEqual(len(graph['scopes']), 2)
        inner = [n for n in graph['nodes'] if n['scope'] != 'main']
        self.assertTrue({'接收参数', 'n', '−', '×', '返回给调用处'}.issubset({n['title'] for n in inner}))
        self.assertTrue(any(e['label'] == '递归调用' for e in graph['edges']))
        self.assertTrue(any(e['kind'] == 'return' for e in graph['edges']))
        self.assertLess(len(inner), 80)

    def test_short_circuit_and_unsupported_syntax_are_not_silent(self):
        graph = code_graph('y = a and f()\nz = [x for x in values]\n')
        self.assertTrue(any(e['kind'] == 'guard' and e['label'] == '为真才求值' for e in graph['edges']))
        self.assertTrue(graph['warnings'])
        self.assertTrue(any(n['kind'] == 'unsupported' for n in graph['nodes']))

    def test_reassignment_keeps_each_read_connected_to_the_correct_value_version(self):
        graph = code_graph('a=1\nb=a\na=2\nc=a\n')
        nodes = {n['id']: n for n in graph['nodes']}
        for line, assigned_line in [(2, 1), (4, 3)]:
            read = next(n for n in graph['nodes'] if n['kind'] == 'read' and n.get('symbol') == 'a' and n['line'] == line)
            incoming = next(e for e in graph['edges'] if e['to'] == read['id'] and e['kind'] == 'binding')
            self.assertEqual(nodes[incoming['from']]['assignment_line'], assigned_line)

    def test_arguments_elements_and_lookup_are_individual_nodes(self):
        graph = code_graph('items=[10,20]\nx=f(items[0],2)\n')
        kinds = [n['kind'] for n in graph['nodes']]
        self.assertEqual(kinds.count('element'), 2)
        self.assertEqual(kinds.count('argument'), 2)
        self.assertEqual(kinds.count('lookup'), 1)
        self.assertEqual(kinds.count('receive'), 1)
        self.assertTrue(any(n['kind'] == 'construct' for n in graph['nodes']))
        self.assertTrue(any(n['kind'] == 'container' for n in graph['nodes']))
        for n in graph['nodes']:
            if n['kind'] in ('call', 'lookup', 'construct'):
                self.assertTrue(any(e['from'] == n['id'] and e['kind'] == 'data' for e in graph['edges']))

    def test_parsing_never_executes_user_code(self):
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / 'should_not_exist'
            code_graph(f'open({str(destination)!r}, "w").write("bad")\nraise RuntimeError("bad")\n')
            self.assertFalse(destination.exists())

    def test_whole_view_sections_keep_every_atomic_node_and_short_local_reads(self):
        source = Path('examples/逐行运算.py').read_text()
        graph = code_graph(source)
        view = graph['whole_views'][0]
        self.assertEqual([s['title'] for s in view['sections']],
                         ['设置变量', '计算 total', '判断 total >= 50', '设置变量', '设置变量', '分支汇合', '计算 payment', '输出'])
        originals = {n['id'] for n in graph['nodes']}
        self.assertEqual({n['id'] for n in view['nodes'] if n['kind'] != 'reference'}, originals)
        self.assertTrue(all('section_id' in n for n in view['nodes']))
        nodes = {n['id']: n for n in view['nodes']}
        reads = [n for n in view['nodes'] if n['kind'] == 'read' and n.get('symbol') == 'total']
        for read in reads:
            incoming = next(e for e in view['edges'] if e['to'] == read['id'] and e['kind'] == 'binding')
            ref = nodes[incoming['from']]
            self.assertEqual(ref['kind'], 'reference')
            self.assertEqual(ref['section_id'], read['section_id'])
            self.assertLess(abs(ref['y'] - read['y']), 100)
            self.assertEqual(nodes[ref['origin_id']]['assignment_line'], 3)
        self.assertEqual(len(view['section_links']), 8)
        for edge in view['edges']:
            if edge['kind'] in ('data', 'binding'):
                self.assertEqual(nodes[edge['from']]['section_id'], nodes[edge['to']]['section_id'])

    def test_whole_view_local_reference_preserves_assignment_version_and_loop_feedback(self):
        graph = code_graph('a=1\nb=a\na=2\nc=a\n')
        view = graph['whole_views'][0]
        refs = [n for n in view['nodes'] if n['kind'] == 'reference']
        self.assertEqual({(n['line'], n['origin_line']) for n in refs}, {(2, 1), (4, 3)})
        graph = code_graph('i=0\nwhile i<3:\n    i=i+1\nprint(i)\n')
        view = graph['whole_views'][0]
        slots = {n['id'] for n in view['nodes'] if n['title'] == '循环中的 i'}
        self.assertTrue(any(e['to'] in slots and e['label'] == '下一轮的值' for e in view['edges']))

    def test_whole_view_branch_lanes_and_regions_do_not_overlap(self):
        graph = code_graph('a=2\nif a>0:\n    b=a+1\nelse:\n    b=a-1\nc=b*2\n')
        view = graph['whole_views'][0]
        fork = view['flow_tree']['children'][0]['children'][1]['children'][1]
        self.assertEqual(fork['kind'], 'fork')
        self.assertEqual(fork['labels'], ['条件成立', '条件不成立'])
        ids = [child['children'][0]['id'] for child in fork['children']]
        self.assertEqual([next(s['line'] for s in view['sections'] if s['id'] == id) for id in ids], [3, 5])
        for a, b in zip(view['sections'], view['sections'][1:]):
            self.assertLess(a['y'] + a['height'], b['y'])
        for i, a in enumerate(view['nodes']):
            for b in view['nodes'][i+1:]:
                self.assertFalse(a['x'] < b['x'] + b['width'] and b['x'] < a['x'] + a['width'] and
                                 a['y'] < b['y'] + b['height'] and b['y'] < a['y'] + a['height'],
                                 (a['title'], b['title']))

    def test_nested_branches_stay_inside_their_parent_lane(self):
        view = code_graph('if a:\n    if b:\n        x=1\n    else:\n        x=2\nelse:\n    x=3\n')['whole_views'][0]
        outer = view['flow_tree']['children'][0]['children'][0]['children'][1]
        inner = outer['children'][0]['children'][0]['children'][1]
        self.assertEqual(inner['kind'], 'fork')
        self.assertEqual(inner['labels'], ['条件成立', '条件不成立'])
        self.assertEqual(outer['children'][1]['children'][0]['id'],
                         next(s['id'] for s in view['sections'] if s['line'] == 7 and s['title'] == '设置变量'))

    def test_whole_view_function_entry_and_return_keep_real_control_edges(self):
        graph = code_graph('def f(n):\n    if n<=0:\n        return 0\n    return n+1\nx=f(2)\n')
        view = graph['whole_views'][1]
        self.assertEqual(view['sections'][0]['title'], '函数入口')
        self.assertEqual(len(view['section_links']), 4)
        self.assertEqual(len({n['id'] for n in view['nodes']}), len(view['nodes']))

    def test_worker_survives_partial_code_and_recovers_with_new_revision(self):
        requests = [{'id': 1, 'source': 'if x >'}, {'id': 2, 'source': 'x=2\ny=x+1\n'}]
        result = subprocess.run([sys.executable, '-u', '-m', 'pyvis_runtime.blueprint'],
            input=''.join(json.dumps(r) + '\n' for r in requests), capture_output=True, text=True, timeout=5)
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(responses[0]['id'], 1)
        self.assertEqual(responses[0]['error']['line'], 1)
        self.assertEqual(responses[1]['id'], 2)
        self.assertTrue(responses[1]['graph']['nodes'])
        self.assertEqual(result.returncode, 0)
