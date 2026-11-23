from pathlib import Path
import unittest
from pyvis_runtime.blueprint import code_graph


def leaves(tree):
    if tree['kind'] == 'section':
        return [tree['id']]
    return [id for child in tree.get('children', []) for id in leaves(child)]


class FlowTreeTests(unittest.TestCase):
    def test_while_true_has_no_false_exit_but_keeps_the_break_target(self):
        graph = code_graph('while True:\n    if input()=="q":\n        break\nprint("结束")\n')
        header = next(n for n in graph['nodes'] if n['kind'] == 'condition' and n['line'] == 1)
        self.assertFalse(any(e['from'] == header['id'] and e['label'] == '结束' for e in graph['edges']))
        control = next(n for n in graph['nodes'] if n['kind'] == 'control')
        target = next(n for n in graph['nodes'] if n['title'] == '离开循环')
        self.assertTrue(any(e['from'] == control['id'] and e['to'] == target['id'] for e in graph['edges']))

    def test_nested_groups_keep_source_boundaries_and_end_cards_do_not_repeat_headers(self):
        view = code_graph('i=0\nwhile i<3:\n    if i:\n        print(i)\n    i+=1\nprint(i)\n')['whole_views'][0]
        def groups(tree):
            return ([tree] if tree['kind'] == 'group' else []) + [g for c in tree.get('children', []) for g in groups(c)]
        outer, inner = groups(view['flow_tree'])
        self.assertEqual((outer['line'], outer['end_line']), (2, 5))
        self.assertEqual((inner['line'], inner['end_line']), (3, 4))
        self.assertTrue(set(leaves(inner)).issubset(leaves(outer)))
        end = next(s for s in view['sections'] if s['title'] == '离开循环')
        self.assertEqual(end['code'], '')
        self.assertEqual(end['category'], 'LoopExit')
        self.assertEqual(end['teaching']['line'], end['line'])

    def test_real_menu_and_function_entry_appear_once_in_structured_paths(self):
        sources = [(Path(__file__).parent / 'fixtures/menu_decimal.py').read_text(),
                   'def f(n):\n    if n:\n        return n\n    return 0\nx=f(3)\n']
        for source in sources:
            for view in code_graph(source)['whole_views']:
                ids = leaves(view['flow_tree'])
                self.assertEqual(set(ids), {s['id'] for s in view['sections']})
                self.assertEqual(len(ids), len(set(ids)))

    def test_loop_paths_retain_return_and_break_edges_without_fabricating_fallthrough(self):
        view = code_graph('i=0\nwhile i<3:\n    if i==1:\n        break\n    i+=1\nprint(i)\n')['whole_views'][0]
        sections = {s['id']: s for s in view['sections']}
        back = next(link for link in view['section_links'] if link['label'] == '下一轮')
        self.assertEqual(sections[back['target']]['line'], 2)
        break_id = next(n['section_id'] for n in view['nodes'] if n['kind'] == 'control' and n['line'] == 4)
        break_links = [link for link in view['section_links'] if link['source'] == break_id]
        self.assertTrue(break_links)
        self.assertTrue(all(sections[link['target']]['title'] == '离开循环' for link in break_links))

    def test_exception_handlers_have_alternative_paths_and_finally_follows_them(self):
        view = code_graph('try:\n    x=f()\nexcept ValueError:\n    x=1\nexcept TypeError:\n    x=2\nfinally:\n    print("结束")\n')['whole_views'][0]
        def forks(tree):
            return ([tree] if tree['kind'] == 'fork' else []) + [f for c in tree.get('children', []) for f in forks(c)]
        alternatives = next(t for t in forks(view['flow_tree']) if t['labels'] == ['ValueError', 'TypeError'])
        self.assertEqual(len(alternatives['children']), 2)
        self.assertTrue(set(leaves(alternatives['children'][0])).isdisjoint(leaves(alternatives['children'][1])))
        self.assertTrue(any(s['title'] == '准备执行 finally' for s in view['sections']))
