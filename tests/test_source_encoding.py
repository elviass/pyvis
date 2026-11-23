import unittest

from pyvis_runtime.source_encoding import convert_source, decode_source, encode_source


class SourceEncodingTests(unittest.TestCase):
    def test_bom_and_paired_or_legacy_line_endings(self):
        text = '#!/usr/bin/env python3\nprint("你好")\n'
        converted = convert_source(text, 'gbk')
        self.assertEqual(converted.splitlines()[1], '# -*- coding: gbk -*-')
        for ending in ('\r', '\n', '\r\n'):
            source = converted.replace('\n', ending)
            data = encode_source(source, 'gbk')
            self.assertEqual(decode_source(data), (source, 'gbk'))
        utf8 = convert_source(converted, 'utf-8-sig')
        data = encode_source(utf8, 'utf-8-sig')
        self.assertTrue(data.startswith(b'\xef\xbb\xbf'))
        self.assertEqual(decode_source(data), (utf8, 'utf-8-sig'))

    def test_unrepresentable_data_fails_without_replacement(self):
        with self.assertRaises(UnicodeEncodeError):
            convert_source('print("🌱")\n', 'gbk')

    def test_unrelated_comment_is_preserved(self):
        source = 'print("你好")\n# coding: ascii\n'
        converted = convert_source(source, 'gbk')
        self.assertEqual(converted, '# -*- coding: gbk -*-\n' + source)
