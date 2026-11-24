"""Find local source candidates without executing Python imports."""
import ast


def import_candidates(tree, filename, root, suffixes=('.py',)):
    def candidates(base, module):
        parts = module.split('.') if module else []
        for count in range(1, len(parts) + 1):
            path = base.joinpath(*parts[:count])
            for suffix in suffixes:
                yield path.with_suffix(suffix)
            yield path / '__init__.py'

    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                yield from candidates(root, alias.name)
        elif isinstance(node, ast.ImportFrom):
            base = filename.parent if node.level else root
            for _ in range(max(0, node.level - 1)):
                base = base.parent
            yield from candidates(base, node.module)
            for alias in node.names:
                if alias.name != '*':
                    yield from candidates(base, '.'.join(filter(None, (node.module, alias.name))))
