import unittest
from pyvis_runtime.code_intelligence import analyze
from pyvis_runtime.spelling import inspect_spelling
from pyvis_runtime.semantic_analysis import complete


class EditorPresentationTests(unittest.TestCase):
    def test_missing_final_newline_is_left_to_explicit_formatting(self):
        from pyvis_runtime.editor_tools import format_source

        filename = '/tmp/style.py'
        source = 'print(1)'
        self.assertEqual(analyze(source, filename)['diagnostics'], [])
        self.assertEqual(format_source(source, filename), source + '\n')
        issues = analyze('print(1', filename)['diagnostics']
        self.assertTrue(any(issue['blocking'] for issue in issues))

    def test_inspection_categories_are_not_an_arbitrary_color_cycle(self):
        source = 'import math\n# helo\nvalue: int = "text"\nprint(value)\n'
        issues = analyze(source,'/tmp/style.py')['diagnostics']
        kinds = {d['code']:d['presentation'] for d in issues}
        self.assertEqual(kinds['F401'],'unused')
        self.assertEqual(kinds['Typo'],'typo')
        self.assertEqual(kinds['invalid-assignment'],'warning')
        syntax = analyze('if True\n pass','/tmp/style.py')['diagnostics']
        self.assertTrue(any(d['presentation']=='error' for d in syntax))

    def test_typo_ranges_split_identifiers_and_preserve_unicode_columns(self):
        source = '# 中文 helo\ncalulate_total = "helo"\n'
        issues = inspect_spelling(source,'/tmp/style.py')
        self.assertTrue(any(d['line']==1 and d['column']==6 and d['end_column']==10 for d in issues))
        self.assertTrue(any(d['line']==2 and d['column']==1 and d['end_column']==9 for d in issues))
        for d in issues:
            self.assertEqual(d['severity'],'typo')
            self.assertFalse(d['blocking'])
            if d['line']==2 and d['column']==1:
                self.assertTrue(all('edits' not in f for f in d['fixes']))

    def test_typo_fixes_only_edit_prose_and_dictionary_does_not_change_source(self):
        source='print("helo")\n'
        issues=inspect_spelling(source,'/tmp/style.py')
        self.assertEqual(len(issues),1)
        self.assertTrue(any(f['action']=='dictionary_add' for f in issues[0]['fixes'] if 'action' in f))
        fixes=[f for f in issues[0]['fixes'] if 'edits' in f]
        self.assertTrue(any(f['edits'][0]['content']=='hello' for f in fixes))
        self.assertEqual(inspect_spelling(source,'/tmp/style.py',accepted=['helo']),[])

    def test_technical_names_urls_escapes_and_chinese_are_not_spelling_errors(self):
        self.assertEqual(inspect_spelling('import asyncio\nargs = "https://examplle.invalid/helo \\n 中文"\nprint(args)\n','/tmp/style.py'),[])

    def test_long_word_is_skipped_without_losing_nearby_spelling_suggestions(self):
        from unittest.mock import patch
        from pyvis_runtime.spelling import alternatives

        source = f'# {"z" * 100_000} helo\n'
        with patch('pyvis_runtime.spelling.alternatives', wraps=alternatives) as suggest:
            issues = inspect_spelling(source, '/tmp/style.py')

        suggest.assert_called_once_with('helo')
        self.assertEqual(len(issues), 1)
        self.assertEqual(issues[0]['column'], 100_004)

    def test_pycharm_suppression_uses_comments_and_keeps_syntax_errors(self):
        source = '# noinspection PyTypeChecker\nvalue: int = "text"\nprint(value)\n'
        self.assertFalse(any(d['code']=='invalid-assignment' for d in analyze(source,'/tmp/style.py')['diagnostics']))
        source = '# noinspection ALL\nif True\n pass\n'
        self.assertTrue(any(d['severity']=='error' for d in analyze(source,'/tmp/style.py')['diagnostics']))

    def test_completion_context_is_available_with_incomplete_loop_and_annotations(self):
        source='def report(Grades: dict[str,int]):\n    for'
        result=complete(source,'/tmp/style.py',2,7)
        self.assertTrue(any(s['name']=='Grades' and s['detail']=='dict' for s in result['context']['symbols']))
        source='def load() -> dict[str,int]:\n    return {}\nGrades=load()\nfor'
        result=complete(source,'/tmp/style.py',4,3)
        self.assertTrue(any(s['name']=='Grades' and s['detail']=='dict' for s in result['context']['symbols']))

if __name__=='__main__':unittest.main()
