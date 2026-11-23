import unittest
from pyvis_runtime.inline_validation import validate_inline


class InlineValidationTests(unittest.TestCase):
    def test_fim_accepts_loop_bindings_and_preserves_original_suffix(self):
        source = 'scores=[1,2]\nfor\nprint("done")'
        prediction = ' index in scores:\n    print(index)'
        self.assertEqual(validate_inline(source, 2, 3, prediction)['prediction'], prediction)

    def test_unknown_variables_and_sibling_locals_are_filtered(self):
        self.assertIsNone(validate_inline('for', 1, 3, ' item in missing:\n    print(item)')['prediction'])
        source = 'def first():\n    secret=1\n\ndef second():\n    return'
        self.assertIsNone(validate_inline(source, 5, 10, ' secret')['prediction'])

    def test_truncated_tail_is_reduced_to_valid_code(self):
        source = 'values=[1,2]\nfor'
        prediction = ' item in values:\n    print(item)\n    if'
        self.assertEqual(validate_inline(source, 2, 3, prediction)['prediction'],
                         ' item in values:\n    print(item)')

    def test_unicode_columns_and_invalid_generated_syntax(self):
        self.assertEqual(validate_inline('数据=[1]\nfor', 2, 3,
                         ' 值 in 数据:\n    print(值)')['prediction'],
                         ' 值 in 数据:\n    print(值)')
        self.assertIsNone(validate_inline('value=', 1, 6, '```1```')['prediction'])
        self.assertIsNone(validate_inline('value=', 1, 6, ' !!!')['prediction'])
