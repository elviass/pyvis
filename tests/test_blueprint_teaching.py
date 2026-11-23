from pathlib import Path
import unittest
from pyvis_runtime.blueprint import code_graph


class TeachingTests(unittest.TestCase):
    def test_reading_overview_keeps_function_body_and_alternative_paths_nested(self):
        graph = code_graph('''def parse(values):
    for v in values:
        try:
            if v > 0:
                return v
        except TypeError:
            continue
    return None

result = parse([0, "x", 5])
print(result)
''')
        function, call, output = graph['reading']
        self.assertEqual([function['line'], call['line'], output['line']], [1, 10, 11])
        self.assertEqual(function['kind'], 'definition')
        loop = function['branches'][0]['items'][0]
        guarded = loop['branches'][0]['items'][0]
        self.assertEqual([arm['label'] for arm in guarded['branches']],
                         ['正常路径', 'TypeError 异常'])
        decision = guarded['branches'][0]['items'][0]
        self.assertEqual(decision['branches'][0]['items'][0]['terminal'], True)
        self.assertEqual(decision['branches'][1]['empty'], '跳过这个分支')
        self.assertIn('parse', call['title'])

    def test_loop_explains_test_body_update_and_return_without_claiming_actual_values(self):
        graph = code_graph('number=1\ntotal=0\nwhile number<=50:\n    total+=number\n    number+=1\nprint(total)\n')
        lesson = graph['whole_views'][0]['sections'][1]['teaching']
        self.assertEqual(lesson['title'], '循环条件：number 小于或等于 50')
        self.assertEqual([s['line'] for s in lesson['steps']], [3, 4, 5, 3])
        self.assertIn('将 number 加到 total', lesson['steps'][1]['label'])
        self.assertEqual(lesson['steps'][-1]['kind'], 'repeat')
        self.assertNotIn('1275', str(lesson))
        self.assertIn('读取变量 number 的当前值', lesson['explanation'])

    def test_input_cleanup_order_matches_actual_calls(self):
        graph = code_graph('choice=input("选择").strip().lower()\n')
        lesson = graph['line_views'][0]['teaching']
        self.assertIn('读取并处理用户输入', lesson['title'])
        self.assertEqual([s.get('function_suffix') for s in lesson['steps']], ['input', '.strip', '.lower', None])
        self.assertIn('移除首尾空白字符', lesson['steps'][1]['label'])
        self.assertIn('转换为小写', lesson['steps'][2]['label'])

    def test_assignment_and_branch_use_plain_purpose_and_correct_source_lines(self):
        graph = code_graph('a=1\nb=2\nc=a*b\nif c>2:\n    print(c)\nelse:\n    print("小")\n')
        init = graph['whole_views'][0]['sections'][0]['teaching']
        self.assertIn('a、b', init['explanation'])
        calc = next(v['teaching'] for v in graph['line_views'] if v['line'] == 3)
        self.assertIn('相乘', calc['title'])
        self.assertIn('将结果赋给 c', calc['explanation'])
        branch = next(s['teaching'] for s in graph['whole_views'][0]['sections'] if s['title'].startswith('判断 '))
        self.assertEqual([s['line'] for s in branch['steps']], [4, 5, 7])
        self.assertIn('一次判断只选择一条分支', branch['explanation'])

    def test_end_of_loop_is_not_taught_as_another_iteration_and_error_handler_has_own_lesson(self):
        graph = code_graph('try:\n    while True:\n        break\nexcept ValueError:\n    print("错")\n')
        sections = graph['whole_views'][0]['sections']
        end = next(s['teaching'] for s in sections if s['title'] == '离开循环')
        self.assertEqual(end['title'], '当前循环结束')
        handler = next(v['teaching'] for v in graph['line_views'] if v['line'] == 4)
        self.assertEqual(handler['title'], '处理匹配此类型的异常')

    def test_long_loop_body_marks_continuation_and_unconditional_break_has_no_fake_repeat(self):
        graph = code_graph('while True:\n    print(1)\n    print(2)\n    print(3)\n    print(4)\n')
        steps = graph['whole_views'][0]['sections'][0]['teaching']['steps']
        self.assertEqual(steps[-2]['line'], 5)
        self.assertIn('后续步骤', steps[-2]['label'])
        graph = code_graph('while True:\n    break\n')
        lesson = graph['whole_views'][0]['sections'][0]['teaching']
        self.assertFalse(any(s['kind'] == 'repeat' for s in lesson['steps']))
        graph = code_graph('x=20\n')
        self.assertEqual([s['target_kind'] for s in graph['line_views'][0]['teaching']['steps']], ['read', 'write'])

    def test_actual_menu_has_guides_for_every_region_and_plain_five_repetitions(self):
        source = (Path(__file__).parent / 'fixtures' / 'menu_decimal.py').read_text()
        view = code_graph(source)['whole_views'][0]
        self.assertTrue(all(s['teaching']['title'] and s['teaching']['explanation'] for s in view['sections']))
        repetition = next(s['teaching'] for s in view['sections'] if s['title'].startswith('for _ in range'))
        self.assertIn('重复执行循环体 5 次', repetition['title'])

    def test_generated_explanations_use_precise_terms_without_metaphors(self):
        graph = code_graph('a=1\nb=2\nc=a+b\nwhile c<5:\n    c+=1\nprint(c)\n')
        lessons = [v['teaching'] for v in graph['line_views']]
        wording = ' '.join(' '.join([v['title'], v['explanation'], *[step['label'] for step in v['steps']]]) for v in lessons)
        for phrase in ('盒子', '请 ', '拿出', '交回去', '回头', '做事', '看看'):
            self.assertNotIn(phrase, wording)
        self.assertIn('读取', wording)
        self.assertIn('赋给', wording)
        self.assertIn('条件成立', wording)
        self.assertEqual([step['line'] for step in lessons[3]['steps']], [4, 5, 4])
