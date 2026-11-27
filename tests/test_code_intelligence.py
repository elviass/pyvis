import contextlib
import io
import unittest
from unittest.mock import patch
from pyvis_runtime.code_intelligence import analyze, check_sources


class IntelligenceTests(unittest.TestCase):
    def test_compile_catches_context_errors_as_well_as_parser_errors(self):
        for source, code in [('return 1', 'SyntaxError'), ('break', 'SyntaxError'),
                             ('if True\n    pass', 'SyntaxError'),
                             ('if True:\npass', 'IndentationError')]:
            with self.subTest(source=source):
                result = analyze(source, '/p/main.py')
                self.assertEqual(result['diagnostics'][0]['code'], code)
                self.assertEqual(result['diagnostics'][0]['severity'], 'error')
                self.assertTrue(result['diagnostics'][0]['hint'])

    def test_check_never_executes_module_or_imports_learner_code(self):
        sources = {'/p/main.py': 'from helper import value\nprint("MUST NOT EXECUTE")\n',
                   '/p/helper.py': 'raise RuntimeError("MUST NOT IMPORT")\nvalue=3\n'}
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = check_sources(sources, '/p/main.py', '/p')
        self.assertEqual(output.getvalue(), '')
        self.assertEqual(result['diagnostics'], [])
        self.assertEqual(result['checked'], ['/p/helper.py', '/p/main.py'])

    def test_local_import_error_is_checked_but_unrelated_broken_file_is_not(self):
        sources = {'/p/main.py': 'from helper import value\nprint(value)',
                   '/p/helper.py': 'if True\n pass', '/p/unused.py': '???'}
        result = check_sources(sources, '/p/main.py', '/p')
        self.assertEqual([d['file'] for d in result['diagnostics']], ['/p/helper.py'])
        self.assertNotIn('/p/unused.py', result['checked'])

    def test_project_check_returns_dependency_paths_to_the_client(self):
        with patch('pathlib.Path.read_bytes', side_effect=AssertionError('unexpected read')):
            entry = check_sources({'/p/main.py': 'import helper\n'}, project='/p', discover_imports=True)
            helper = check_sources({'/p/helper.py': 'if True\n    pass\n'},
                                   project='/p', discover_imports=True)
        self.assertEqual(entry['checked'], ['/p/main.py'])
        self.assertEqual(entry['dependencies'], ['/p/helper.py', '/p/helper/__init__.py'])
        self.assertEqual([d['file'] for d in helper['diagnostics']], ['/p/helper.py'])

    def test_package_relative_import_and_import_cycle_remain_finite(self):
        sources = {'/p/main.py': 'from pkg import helper', '/p/pkg/__init__.py': '',
                   '/p/pkg/helper.py': 'from . import other',
                   '/p/pkg/other.py': 'from . import helper\nreturn 1'}
        result = check_sources(sources, '/p/main.py', '/p')
        self.assertEqual(len(result['checked']), 4)
        self.assertEqual(result['diagnostics'][0]['file'], '/p/pkg/other.py')

    def test_unknown_names_are_warnings_and_chinese_column_is_character_based(self):
        result = analyze('价格=20\nprint(价格, missing)', '/p/main.py')
        unresolved = [d for d in result['diagnostics'] if d['code'] == 'UndefinedName']
        self.assertEqual(len(unresolved), 1)
        diagnostic = unresolved[0]
        self.assertEqual(diagnostic['severity'], 'warning')
        self.assertEqual(diagnostic['column'], 11)
        self.assertFalse(any(d['code'] == 'UndefinedName' for d in analyze('from math import *\nprint(sqrt(4))', 'x.py')['diagnostics']))

    def test_completion_preserves_functions_parameters_scopes_and_known_types(self):
        result = analyze('items=[]\nimport math as m\ndef total(price, count=1):\n    local=price*count\n    return local\nitems.ap', 'x.py')
        symbols = {s['name']: s for s in result['symbols']}
        self.assertEqual(symbols['total']['kind'], '函数')
        self.assertEqual(symbols['price']['start'], 3)
        self.assertEqual(symbols['local']['end'], 5)
        self.assertIn('append', [m['name'] for m in result['members']['items']])
        self.assertIn('sqrt', [m['name'] for m in result['members']['m']])
        partial = analyze('items=[]\nitems.', 'x.py')
        self.assertIn('append', [m['name'] for m in partial['members']['items']])


if __name__ == '__main__':
    unittest.main()


class SemanticCompletionTests(unittest.TestCase):
    def test_prefix_ranking_exact_callables_and_signatures(self):
        from pyvis_runtime.semantic_analysis import complete
        result = complete('pri', '/tmp/pyvis-lesson.py', 1, 3)
        self.assertIn('print', [p['name'] for p in result['completions']])
        self.assertTrue(all(p['name'].startswith('pri') for p in result['completions']))
        result = complete('def calculate(price, count=1):\n    return price*count\ncalculate(2, ',
                          '/tmp/pyvis-lesson.py', 3, 13)
        self.assertEqual(result['signatures'][0]['name'], 'calculate')
        self.assertEqual(result['signatures'][0]['index'], 1)

    def test_chained_members_local_imports_and_scope_without_execution(self):
        import tempfile
        from pathlib import Path
        from pyvis_runtime.semantic_analysis import complete
        with tempfile.TemporaryDirectory() as root:
            Path(root, 'helper.py').write_text(
                'from pathlib import Path\n'
                'Path(__file__ + ".executed").write_text("bad")\n'
                'class Order:\n    def subtotal(self):\n        return 2\n')
            source = 'from helper import Order\nOrder().sub'
            result = complete(source, str(Path(root, 'main.py')), 2, 11, root)
            self.assertIn('subtotal', [p['name'] for p in result['completions']])
            self.assertFalse(Path(root, 'helper.py.executed').exists())
            result = complete('def first():\n    hidden=1\n    return hidden\ndef second():\n    hid',
                              str(Path(root, 'main.py')), 5, 7, root)
            self.assertNotIn('hidden', [p['name'] for p in result['completions']])
