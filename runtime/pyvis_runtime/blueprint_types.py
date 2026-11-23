"""Infer display types from known AST values without running learner code."""
from collections import defaultdict, deque


_NUMBERS = ('bool', 'int', 'float', 'complex')
_SEQUENCES = ('str', 'bytes', 'list', 'tuple')
_COMPARISONS = {'Eq', 'NotEq', 'Lt', 'LtE', 'Gt', 'GtE'}


def _shared_type(types):
    if types and types[0] and all(kind == types[0] for kind in types):
        return types[0]
    return None


def _operator_type(op, types):
    if op in ('Not', 'Is', 'IsNot', 'In', 'NotIn'):
        return 'bool'
    if op in ('And', 'Or'):
        return _shared_type(types)
    if op in _COMPARISONS:
        return 'bool' if len(types) == 2 and all(kind in _NUMBERS + ('str', 'bytes', 'NoneType') for kind in types) else None
    if len(types) == 1:
        kind = types[0]
        if op in ('UAdd', 'USub') and kind in _NUMBERS:
            return 'int' if kind == 'bool' else kind
        if op == 'Invert' and kind in ('bool', 'int'):
            return 'int'
    if len(types) != 2:
        return None
    left, right = types
    if op == 'Add' and left == right and left in _SEQUENCES:
        return left
    if op == 'Mult':
        if left in _SEQUENCES and right in ('bool', 'int'):
            return left
        if right in _SEQUENCES and left in ('bool', 'int'):
            return right
    if left not in _NUMBERS or right not in _NUMBERS:
        return None
    widest = max(types, key=_NUMBERS.index)
    if op in ('LShift', 'RShift', 'BitAnd', 'BitOr', 'BitXor') and widest in ('int', 'bool'):
        if widest == 'bool' and op in ('BitAnd', 'BitOr', 'BitXor'):
            return 'bool'
        return 'int'
    if op == 'Div':
        return 'complex' if widest == 'complex' else 'float'
    if op in ('Add', 'Sub', 'Mult') or op in ('FloorDiv', 'Mod') and widest != 'complex':
        return 'int' if widest == 'bool' else widest
    return None


def annotate_value_types(nodes, edges):
    lookup = {node['id']: node for node in nodes}
    incoming, consumers = defaultdict(list), defaultdict(list)
    for edge in edges:
        if edge['kind'] in ('data', 'binding'):
            incoming[edge['to']].append((edge['port'], edge['from']))
            consumers[edge['from']].append(edge['to'])
    for values in incoming.values():
        values.sort()

    def inferred(node):
        kind = node['kind']
        sources = incoming[node['id']]
        types = [lookup[source].get('value_type') for _, source in sources]
        if kind == 'literal':
            return node.get('literal_type')
        if kind == 'operator':
            if node['title'] == '所有比较成立':
                return 'bool' if _shared_type(types) == 'bool' else None
            return _operator_type(node.get('operator'), types)
        if kind == 'truth':
            return 'bool'
        if kind == 'condition' and node['title'] == '按条件取一个值':
            choices = [value_type for (port, _), value_type in zip(sources, types) if port in (1, 2)]
            return _shared_type(choices) if len(choices) == 2 else None
        if kind == 'write':
            return types[0] if sources and sources[0][0] == 0 else None
        if kind == 'variable':
            return _shared_type(types) if len(types) == len(node['inputs']) else None
        if kind in ('value', 'symbol', 'read', 'element', 'argument', 'return', 'pending_return'):
            return types[0] if len(types) == 1 else None
        return None

    # Once proved, a type is stable. Unknown loop feedback and mixed branches
    # stay neutral, even when an earlier assignment had a known type.
    pending = deque(lookup)
    queued = set(lookup)
    while pending:
        node_id = pending.popleft()
        queued.remove(node_id)
        node = lookup[node_id]
        value_type = node.get('value_type') or inferred(node)
        if not value_type:
            continue
        node['value_type'] = value_type
        for consumer in consumers[node_id]:
            if consumer not in queued and not lookup[consumer].get('value_type'):
                pending.append(consumer)
                queued.add(consumer)
