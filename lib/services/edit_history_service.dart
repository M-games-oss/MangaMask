import 'package:image/image.dart' as img;

class HistoryEntry {
  HistoryEntry(this.layerId, this.pixelsBefore);
  final String layerId;
  final img.Image pixelsBefore;
}

/// Simple linear undo/redo stack. Each entry stores the *previous* pixel
/// state of one layer, captured right before a destructive edit (brush
/// stroke, cutout, inpaint). Redo re-applies by walking forward again.
class EditHistoryService {
  final List<HistoryEntry> _undoStack = [];
  final List<HistoryEntry> _redoStack = [];
  static const int maxDepth = 40;

  void recordBeforeEdit(String layerId, img.Image currentPixels) {
    _undoStack.add(HistoryEntry(layerId, img.Image.from(currentPixels)));
    if (_undoStack.length > maxDepth) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  /// Pops the last entry; caller swaps it into the layer and must push the
  /// layer's *current* state onto redo via [pushRedo].
  HistoryEntry? popUndo() {
    if (_undoStack.isEmpty) return null;
    return _undoStack.removeLast();
  }

  void pushRedo(String layerId, img.Image currentPixels) {
    _redoStack.add(HistoryEntry(layerId, img.Image.from(currentPixels)));
  }

  HistoryEntry? popRedo() {
    if (_redoStack.isEmpty) return null;
    return _redoStack.removeLast();
  }

  void pushUndo(String layerId, img.Image currentPixels) {
    _undoStack.add(HistoryEntry(layerId, img.Image.from(currentPixels)));
  }

  void clear() {
    _undoStack.clear();
    _redoStack.clear();
  }
}
