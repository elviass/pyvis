part of re_editor;

abstract class IParagraph {

  double get width;
  double get height;
  double get preferredLineHeight;
  bool get trucated;
  int get length;
  int get lineCount;

  void draw(Canvas canvas, Offset offset);

  TextPosition getPosition(Offset offset);

  TextRange getWord(Offset offset);
  
  InlineSpan? getSpanForPosition(TextPosition position);

  TextRange getRangeForSpan(InlineSpan span);

  TextRange getLineBoundary(TextPosition position);

  Offset? getOffset(TextPosition position);

  List<Rect> getRangeRects(TextRange range);

}
/// Optional presentation-only paragraph decoration. The document and source
/// indices are owned by the editing controller, never by this renderer.
abstract class CodeParagraphDecorator extends ChangeNotifier {
  IParagraph decorate(int index, IParagraph paragraph, TextStyle style, double maxWidth);
}
