import ast
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from pyvis_runtime.code_intelligence import analyze, compile_check
from pyvis_runtime.editor_tools import VENDOR, executable, format_source, inspect_source, type_check
from pyvis_runtime.semantic_analysis import complete, symbol_info


class EditorToolsTests(unittest.TestCase):
    def test_x64_tools_are_available_to_emulated_python_on_windows_arm(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            with (
                patch('pyvis_runtime.editor_tools.sys.platform', 'win32'),
                patch('pyvis_runtime.editor_tools.sysconfig.get_platform', return_value='win-amd64'),
                patch('pyvis_runtime.editor_tools.platform.machine', return_value='ARM64'),
                patch.object(Path, 'home', return_value=home),
            ):
                for tool in ('ruff', 'ty'):
                    with self.subTest(tool=tool):
                        binary = Path(executable(tool))
                        self.assertEqual(binary.name, tool + '.exe')
                        self.assertTrue(binary.is_file())

    def test_offline_mac_and_windows_resources_match_manifest(self):
        records = json.loads((VENDOR / 'manifest.json').read_text())
        self.assertEqual(len(records), 6)
        for item in records:
            with self.subTest(file=item['filename']):
                self.assertEqual(hashlib.sha256((VENDOR / item['filename']).read_bytes()).hexdigest(), item['sha256'])
        for tool in ['ruff', 'ty']:
            self.assertTrue(all(any(x['filename'].startswith(tool + '-') and platform in x['filename'] for x in records)
                                for platform in ['macosx_11_0_arm64', 'macosx_10_12_x86_64', 'win_amd64']))

    def test_unsaved_snapshot_reports_types_arguments_attributes_and_unused_names(self):
        source = 'import math\nx: int = "text"\ndef f(a: int):\n return a\nf()\nf("wrong")\nprint(x.missing)\n'
        diagnostics, failures = inspect_source(source, '/lesson/main.py')
        self.assertEqual(failures, [])
        codes = {d['code'] for d in diagnostics}
        self.assertTrue({'F401', 'invalid-assignment', 'missing-argument', 'invalid-argument-type', 'missing-attribute'} <= codes)
        self.assertTrue(all(d['file'] == '/lesson/main.py' and not d['blocking'] for d in diagnostics))
        self.assertTrue(all(d['line'] > 0 and d['column'] > 0 and d['end_column'] >= d['column'] for d in diagnostics))

    def test_relative_import_and_unsaved_dependency_types_use_same_snapshot(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'pkg').mkdir()
            (root / 'pkg/__init__.py').write_text('')
            helper = root / 'pkg/helper.py'
            helper.write_text('def f(value: int) -> int:\n    return value\n')
            filename = str(root / 'pkg/main.py')
            source = 'from .helper import f\nf("text")\n'
            records = type_check(source, filename, folder)
            self.assertEqual([d['code'] for d in records], ['invalid-argument-type'])
            records = type_check(source, filename, folder, {str(helper): 'def f(value: str) -> str:\n    return value\n'})
            self.assertEqual(records, [])
            self.assertIn('int', helper.read_text())
            self.assertFalse((root / 'pkg/main.py').exists())

    def test_inspection_and_navigation_never_execute_user_modules(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            helper = root / 'helper.py'
            helper.write_text('from pathlib import Path\nPath(__file__+".executed").write_text("bad")\n'
                              'def calculate(a: int) -> int:\n    return a\n')
            filename = str(root / 'main.py')
            source = 'from helper import calculate\ncalculate("wrong")\n'
            records, failures = inspect_source(source, filename, folder)
            self.assertEqual(failures, [])
            self.assertIn('invalid-argument-type', [d['code'] for d in records])
            result = symbol_info(source, filename, 2, 5, folder)
            self.assertEqual(result['definitions'][0]['file'], str(helper))
            self.assertFalse((root / 'helper.py.executed').exists())
            self.assertFalse((root / '__pycache__').exists())

    def test_format_and_optimize_are_explicit_source_transformations(self):
        source = "values={'name':1,'age':2}\nprint(values)\n"
        formatted = format_source(source, '/lesson/main.py')
        self.assertEqual(ast.dump(ast.parse(source)), ast.dump(ast.parse(formatted)))
        self.assertIn("'name'", formatted)
        self.assertIn("'age'", formatted)
        optimized = format_source('import math\nfrom pathlib import Path\nprint(Path("."))\n', '/lesson/main.py', imports=True)
        self.assertNotIn('import math', optimized)
        self.assertIn('from pathlib import Path', optimized)
        selected = format_source('a=1\nb=2\n', '/lesson/main.py', selection='2:1-2:4')
        self.assertTrue(selected.startswith('a=1\n'))
        self.assertIn('b = 2', selected)

    def test_safe_fixes_are_edits_not_automatic_code_changes(self):
        source = 'import math\nprint("hello")\n'
        result = analyze(source, '/lesson/main.py')
        unused = next(d for d in result['diagnostics'] if d['code'] == 'F401')
        self.assertEqual(unused['fixes'][0]['applicability'], 'safe')
        self.assertEqual(unused['fixes'][0]['edits'][0]['content'], '')
        result = analyze('"""Lesson."""\nfrom __future__ import annotations\nprint(math.pi)\n', '/lesson/main.py')
        missing = next(d for d in result['diagnostics'] if d['code'] == 'UndefinedName')
        fix = missing['fixes'][0]
        self.assertEqual(fix['edits'][0]['location'], {'row': 3, 'column': 1})
        self.assertEqual(fix['edits'][0]['content'], 'import math\n')
        self.assertTrue(compile_check('return 1', 'main.py')[0]['blocking'])

    def test_completion_has_real_zero_argument_behavior_and_lookup_documentation(self):
        source = 'def empty():\n    pass\nemp'
        item = next(x for x in complete(source, '/lesson/main.py', 3, 3)['completions'] if x['name'] == 'empty')
        self.assertFalse(item['has_parameters'])
        docs = symbol_info('pri', '/lesson/main.py', 1, 3, action='documentation', candidate='print')
        self.assertIn('print', docs['documentation'][0]['text'])
        result = complete('Grades={"math":90}\nGrades["ma', '/lesson/main.py', 2, 10)
        self.assertIn('"math"', [p['name'] for p in result['completions']])

    def test_quoted_brackets_and_multiline_diagnostics_have_precise_source_ranges(self):
        result = analyze('text="[not a bracket]"\nvalues=[1,(2+3)]\n', '/lesson/main.py')
        pairs = result['brackets']
        self.assertEqual(len(pairs), 2)
        self.assertTrue(all(pair['start'][0] == 2 for pair in pairs))
        result = analyze('价格: int = "错误"\n', '/lesson/main.py')
        diagnostic = next(d for d in result['diagnostics'] if d['code'] == 'invalid-assignment')
        self.assertEqual(diagnostic['column'], 11)


if __name__ == '__main__':
    unittest.main()
