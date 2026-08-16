/// All editing tools available on the canvas toolbar.
enum ToolType {
  pan,           // move/zoom canvas
  smartSelect,   // on-device flood-fill "AI" region select (tap)
  aiClickSelect, // SAM backend brush select: drag to add include points,
                 // toggle "exclude" to correct bleed into an overlapping
                 // part, review candidate mask(s) before committing
  polygonLasso,  // manual point-by-point lasso
  magneticLasso, // free-draw lasso that snaps to detected line-art edges
  brushErase,    // manual eraser brush
  restoreBrush,  // restores original pixels (undoes any destructive edit locally)
  aiRemoveBrush, // AI inpainting brush (backend) - removes & fills content intelligently
  moveLayer,     // drag the active layer around
}

enum SelectionMode { newLayer, addToSelection, subtractFromSelection }

extension ToolTypeLabel on ToolType {
  String get label {
    switch (this) {
      case ToolType.pan:
        return 'Pan/Zoom';
      case ToolType.smartSelect:
        return 'Smart Select';
      case ToolType.aiClickSelect:
        return 'AI Brush Select (SAM)';
      case ToolType.polygonLasso:
        return 'Polygon Lasso';
      case ToolType.magneticLasso:
        return 'Magnetic Lasso';
      case ToolType.brushErase:
        return 'Eraser';
      case ToolType.restoreBrush:
        return 'Restore Brush';
      case ToolType.aiRemoveBrush:
        return 'AI Remove Brush';
      case ToolType.moveLayer:
        return 'Move Layer';
    }
  }
}