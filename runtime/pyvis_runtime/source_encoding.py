"""Read and convert Python source using its BOM or PEP 263 declaration."""
import codecs
import io
import re
import tokenize


_COOKIE = re.compile(r'^[ \t\f]*#.*?coding[:=][ \t]*([-\w.]+)', re.ASCII)
_BLANK_OR_COMMENT = re.compile(r'^[ \t\f]*(?:#|$)')


def source_tokens(source):
    """Keep tokens produced before a syntax error in a partial edit."""
    try:
        yield from tokenize.generate_tokens(io.StringIO(source).readline)
    except (tokenize.TokenError, IndentationError, SyntaxError):
        pass


def decode_source(data):
    # Check the first two logical lines even for files using legacy CR endings.
    header = b'\n'.join(re.split(rb'\r\n|\r|\n', data, maxsplit=2)[:2])
    encoding, _ = tokenize.detect_encoding(io.BytesIO(header).readline)
    return data.decode(encoding), codecs.lookup(encoding).name


def convert_source(source, encoding):
    """Update or insert a declaration when one is needed, keeping any shebang."""
    target = codecs.lookup(encoding).name
    declared = 'utf-8' if target == 'utf-8-sig' else target
    lines = source.split('\n')
    match = None
    for index in range(min(2, len(lines))):
        if match := _COOKIE.match(lines[index]):
            original = match.group(1)
            try:
                matches = codecs.lookup(original).name == declared
            except LookupError:
                matches = False
            if not matches:
                start, end = match.span(1)
                lines[index] = lines[index][:start] + declared + lines[index][end:]
            break
        if not _BLANK_OR_COMMENT.match(lines[index]):
            break
    if match is None and declared != 'utf-8':
        lines.insert(1 if lines[0].startswith('#!') else 0, f'# -*- coding: {declared} -*-')
    converted = '\n'.join(lines)
    encode_source(converted, target)
    return converted


def encode_source(source, encoding):
    target = codecs.lookup(encoding).name
    data = source.encode(target)
    decoded, detected = decode_source(data)
    if detected != target or decoded != source:
        raise ValueError('编码声明和所选编码不一致，请在状态栏重新选择文件编码。')
    return data
