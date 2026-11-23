"""Conservative read/assignment analysis to avoid unused synthetic loop slots."""
import ast


class Names(ast.NodeVisitor):
    def __init__(self): self.loaded = set(); self.stored = set()
    def visit_Name(self, node):
        (self.loaded if isinstance(node.ctx, ast.Load) else self.stored).add(node.id)
    def visit_FunctionDef(self, node): pass
    def visit_AsyncFunctionDef(self, node): pass
    def visit_ClassDef(self, node): pass
    def visit_Lambda(self, node): pass


def names(node):
    visitor = Names()
    if node is not None: visitor.visit(node)
    return visitor


def read_before_write(body, assigned=None):
    assigned, reads = set(assigned or ()), set()
    def load(node): reads.update(names(node).loaded - assigned)
    for stmt in body:
        if isinstance(stmt, ast.If):
            load(stmt.test)
            yes, yes_reads = read_before_write(stmt.body, assigned)
            no, no_reads = read_before_write(stmt.orelse, assigned)
            reads.update(yes_reads | no_reads)
            reaching = [s for s in (yes, no) if s is not None]
            if not reaching: return None, reads
            assigned = set.intersection(*reaching)
        elif isinstance(stmt, (ast.For, ast.AsyncFor, ast.While)):
            load(stmt.test if isinstance(stmt, ast.While) else stmt.iter)
            target = set() if isinstance(stmt, ast.While) else names(stmt.target).stored
            _, inner = read_before_write(stmt.body, assigned | target)
            _, exhausted = read_before_write(stmt.orelse, assigned)
            reads.update(inner | exhausted)
        elif isinstance(stmt, ast.Try):
            normal, body_reads = read_before_write(stmt.body, assigned)
            paths = []
            reads.update(body_reads)
            if normal is not None:
                normal, other = read_before_write(stmt.orelse, normal)
                reads.update(other)
                if normal is not None: paths.append(normal)
            for handler in stmt.handlers:
                load(handler.type)
                handled, other = read_before_write(handler.body, assigned | ({handler.name} if handler.name else set()))
                reads.update(other)
                if handled is not None: paths.append(handled - ({handler.name} if handler.name else set()))
            joined = set.intersection(*paths) if paths else assigned
            final, other = read_before_write(stmt.finalbody, joined)
            reads.update(other)
            if final is None or not paths: return None, reads
            assigned = final
        elif isinstance(stmt, (ast.With, ast.AsyncWith)):
            for item in stmt.items:
                load(item.context_expr)
                if item.optional_vars: load(item.optional_vars); assigned.update(names(item.optional_vars).stored)
            result, other = read_before_write(stmt.body, assigned)
            reads.update(other)
            if result is None: return None, reads
            assigned = result
        else:
            load(stmt)
            if isinstance(stmt, ast.AugAssign) and isinstance(stmt.target, ast.Name) and stmt.target.id not in assigned:
                reads.add(stmt.target.id)
            if isinstance(stmt, (ast.Break, ast.Continue, ast.Return, ast.Raise)): return None, reads
            assigned.update(names(stmt).stored)
    return assigned, reads


def needed_after(builder, stmt):
    class Later(Names):
        def visit_Name(self, node):
            if isinstance(node.ctx, ast.Load) and node.lineno > stmt.end_lineno:
                self.loaded.add(node.id)
    later = Later()
    for child in builder.scope_bodies.get(builder.scope, []): later.visit(child)
    for frame in builder.loops:
        if len(frame) > 2: later.loaded.update(frame[2])
    return later.loaded
