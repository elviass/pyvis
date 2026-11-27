const outputTruncatedNotice = '\n[输出已截断]\n';

/// Stores a UTF-8-bounded prefix of the console output for a run.
class ExecutionOutput {
  ExecutionOutput({this.maxBytes = 2 * 1024 * 1024});

  final int maxBytes;
  final _text = StringBuffer();
  int _bytes = 0;
  bool truncated = false;

  String get text => _text.toString();
  bool get isNotEmpty => _text.isNotEmpty || truncated;
  String get displayText => truncated ? '$text$outputTruncatedNotice' : text;

  void clear() {
    _text.clear();
    _bytes = 0;
    truncated = false;
  }

  void append(String text) {
    if (truncated) return;
    final room = maxBytes - _bytes;
    var end = 0;
    var bytes = 0;
    while (end < text.length && bytes < room) {
      final unit = text.codeUnitAt(end);
      final next = end + 1 < text.length ? text.codeUnitAt(end + 1) : 0;
      final pair =
          unit >= 0xd800 && unit <= 0xdbff && next >= 0xdc00 && next <= 0xdfff;
      final width = pair ? 4 : (unit < 0x80 ? 1 : (unit < 0x800 ? 2 : 3));
      if (bytes + width > room) break;
      bytes += width;
      end += pair ? 2 : 1;
    }
    _bytes += bytes;
    if (end == text.length) {
      _text.write(text);
    } else {
      if (end > 0) _text.write(text.substring(0, end));
      truncated = true;
    }
  }
}
