"""Validate a local FIM prediction without executing learner code."""
import ast
import builtins


def validate_inline(source, line, column, prediction):
    rows = source.split('\n')
    if not 1 <= line <= len(rows) or not 0 <= column <= len(rows[line - 1]):
        return {'prediction': None}
    offset = sum(len(row) + 1 for row in rows[:line - 1]) + column
    # A bounded prefix lets a truncated final model line be discarded safely.
    candidates = [prediction]
    while '\n' in candidates[-1]:
        candidates.append(candidates[-1].rsplit('\n', 1)[0])
    for text in candidates:
        if not text.strip() or '```' in text or '<|' in text:
            continue
        joined = source[:offset] + text + source[offset:]
        try:
            tree = ast.parse(joined)
        except (SyntaxError, ValueError, RecursionError):
            continue
        from .code_intelligence import symbols_for
        symbols, _ = symbols_for(tree)
        end_line = line + text.count('\n')
        unknown = False
        for node in ast.walk(tree):
            if not (isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load)
                    and line <= node.lineno <= end_line):
                continue
            visible = {item['name'] for item in symbols
                       if not item['start'] or item['start'] <= node.lineno <= item['end']}
            if node.id not in visible and not hasattr(builtins, node.id):
                unknown = True
                break
        if unknown:
            continue
        return {'prediction': text}
    return {'prediction': None}
