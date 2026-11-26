import 'dart:collection';
import 'dart:typed_data';

const _blockSize = 32;
const _cachedHeaps = 8;
const maxSnapshotObjects = 1000;

/// Stores ordered object versions in shared blocks. Only heaps that the UI
/// actually looks up are expanded, and those maps have a bounded cache.
class RecordingHeaps {
  final _objects = <(String, Map<String, dynamic>)>[];
  final _blocks = <Uint32List>[];
  final _cache = <_RecordedHeap, Map<String, dynamic>>{};
  var _previousIds = <String, int>{};
  List<int> _previousBlocks = const [];

  Map<String, dynamic> capture(Map<String, dynamic> event,
      {required bool compareFullObjects}) {
    final heap = event['heap'];
    if (heap is _RecordedHeap && identical(heap._store, this)) return event;
    if (heap is! Map<String, dynamic>) return event;
    final before = event['before'];
    final output = event['kind'] == 'output';
    if (output && heap.isEmpty && before == null) return event;

    final objectCount = _objects.length;
    final blockCount = _blocks.length;
    try {
      var ids = _previousIds;
      var blocks = _previousBlocks;
      final saved = {...event};
      if (before is Map<String, dynamic>) {
        (ids, blocks) =
            _capture(before['heap'], ids, blocks, compareFullObjects);
        saved['before'] = {...before, 'heap': _RecordedHeap(this, blocks)};
      }
      (ids, blocks) = _capture(heap, ids, blocks, compareFullObjects);
      saved['heap'] = _RecordedHeap(this, blocks);
      // The worker's output events do not form part of the delta sequence.
      if (!output) {
        _previousIds = ids;
        _previousBlocks = blocks;
      }
      return saved;
    } catch (_) {
      _objects.length = objectCount;
      _blocks.length = blockCount;
      rethrow;
    }
  }

  (Map<String, int>, List<int>) _capture(
      Map<String, dynamic> heap,
      Map<String, int> previous,
      List<int> previousBlocks,
      bool compareFullObjects) {
    final ids = <String, int>{};
    final versions = Uint32List(heap.length);
    var offset = 0;
    for (final entry in heap.entries) {
      final prior = previous[entry.key];
      final value = entry.value;
      final int version;
      if (value == null) {
        if (prior == null) throw const FormatException('执行记录缺少前置对象');
        version = prior;
      } else if (compareFullObjects &&
          prior != null &&
          _sameJson(_objects[prior].$2, value)) {
        version = prior;
      } else {
        version = _objects.length;
        _objects.add((entry.key, value as Map<String, dynamic>));
      }
      ids[entry.key] = version;
      versions[offset++] = version;
    }

    final blocks = <int>[];
    for (var start = 0; start < versions.length; start += _blockSize) {
      final end = (start + _blockSize).clamp(0, versions.length);
      final block = blocks.length;
      final prior =
          block < previousBlocks.length ? previousBlocks[block] : null;
      if (prior != null && _matches(_blocks[prior], versions, start, end)) {
        blocks.add(prior);
      } else {
        blocks.add(_blocks.length);
        _blocks.add(versions.sublist(start, end));
      }
    }
    return (ids, blocks);
  }

  static bool _matches(Uint32List block, Uint32List ids, int start, int end) {
    if (block.length != end - start) return false;
    for (var i = 0; i < block.length; i++) {
      if (block[i] != ids[start + i]) return false;
    }
    return true;
  }

  Map<String, dynamic> _lookup(_RecordedHeap heap) {
    final values = _cache.remove(heap) ??
        {for (final (id, value) in heap._objects) id: value};
    _cache[heap] = values;
    if (_cache.length > _cachedHeaps) _cache.remove(_cache.keys.first);
    return values;
  }

  Map<String, dynamic> get archiveTables => {
        'objects': _objects.map((object) => [object.$1, object.$2]).toList(),
        'heap_blocks': _blocks,
      };

  Map<String, dynamic> archiveEvent(Map<String, dynamic> event) {
    List<int> blocks(Object? heap) =>
        heap is _RecordedHeap ? heap._blocks : const [];
    final before = event['before'];
    return {
      ...event,
      'heap': blocks(event['heap']),
      if (before is Map<String, dynamic>)
        'before': {...before, 'heap': blocks(before['heap'])},
    };
  }

  void readTables(Object? objects, Object? blocks) {
    if (objects is! List || blocks is! List) {
      throw const FormatException('执行记录缺少对象表或快照数据');
    }
    for (final object in objects) {
      if (object is! List ||
          object.length != 2 ||
          object[0] is! String ||
          object[1] is! Map<String, dynamic>) {
        throw const FormatException('执行记录中的对象表无效');
      }
      _objects.add((object[0], object[1]));
    }
    for (final block in blocks) {
      _blocks.add(Uint32List.fromList(
          _indices(block, _objects.length, _blockSize, '快照对象索引')));
      if (_blocks.last.isEmpty) {
        throw const FormatException('执行记录中的快照对象索引无效');
      }
    }
  }

  Map<String, dynamic> readEvent(Map<String, dynamic> event) {
    final before = event['before'];
    return {
      ...event,
      'heap': _readHeap(event['heap']),
      if (before is Map<String, dynamic>)
        'before': {...before, 'heap': _readHeap(before['heap'])},
    };
  }

  _RecordedHeap _readHeap(Object? value) {
    final blocks = _indices(value, _blocks.length,
        (maxSnapshotObjects + _blockSize - 1) ~/ _blockSize, '快照索引');
    return _RecordedHeap(this, blocks);
  }

  static List<int> _indices(
      Object? value, int available, int limit, String label) {
    if (value is! List ||
        value.length > limit ||
        value.any((id) => id is! int || id < 0 || id >= available)) {
      throw FormatException('执行记录中的$label无效或超限');
    }
    return value.cast<int>();
  }
}

class _RecordedHeap extends MapBase<String, dynamic> {
  final RecordingHeaps _store;
  final List<int> _blocks;
  _RecordedHeap(this._store, this._blocks);

  Iterable<(String, Map<String, dynamic>)> get _objects sync* {
    for (final block in _blocks) {
      for (final version in _store._blocks[block]) {
        yield _store._objects[version];
      }
    }
  }

  @override
  Iterable<String> get keys => _objects.map((object) => object.$1);

  @override
  Iterable<dynamic> get values => _objects.map((object) => object.$2);

  @override
  int get length =>
      _blocks.fold(0, (count, block) => count + _store._blocks[block].length);

  @override
  void forEach(void Function(String, dynamic) action) {
    for (final (id, value) in _objects) {
      action(id, value);
    }
  }

  @override
  dynamic operator [](Object? key) => _store._lookup(this)[key];

  @override
  void operator []=(String key, dynamic value) =>
      throw UnsupportedError('快照不可修改');

  @override
  void clear() => throw UnsupportedError('快照不可修改');

  @override
  dynamic remove(Object? key) => throw UnsupportedError('快照不可修改');
}

// Compare old full snapshots without losing key order or the sign of zero.
bool _sameJson(Object? old, Object? next) {
  if (identical(old, next)) return true;
  if (old is Map && next is Map) {
    if (old.length != next.length) return false;
    final entries = next.entries.iterator;
    for (final entry in old.entries) {
      entries.moveNext();
      if (entry.key != entries.current.key ||
          !_sameJson(entry.value, entries.current.value)) {
        return false;
      }
    }
    return true;
  }
  if (old is List && next is List) {
    if (old.length != next.length) return false;
    for (var index = 0; index < old.length; index++) {
      if (!_sameJson(old[index], next[index])) return false;
    }
    return true;
  }
  if (old is num && next is num) {
    return (old is int) == (next is int) &&
        old == next &&
        old.isNegative == next.isNegative;
  }
  return old == next;
}
