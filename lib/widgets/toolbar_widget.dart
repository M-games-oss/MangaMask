import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/tool_type.dart';
import '../services/editor_controller.dart';

class ToolbarWidget extends StatelessWidget {
  const ToolbarWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EditorController>();

    Widget toolButton(ToolType t, IconData icon) {
      final selected = controller.tool == t;
      return IconButton(
        tooltip: t.label,
        icon: Icon(icon, color: selected ? Colors.cyanAccent : Colors.white70),
        onPressed: () => controller.setTool(t),
      );
    }

    return Container(
      color: const Color(0xFF141417),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Persistent label for whichever tool is currently selected —
          // tooltips only show up on long-press/hover, which isn't
          // discoverable enough on a row of similar-looking icons.
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                controller.tool.label,
                style: const TextStyle(
                  color: Colors.cyanAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                toolButton(ToolType.pan, Icons.pan_tool_outlined),
                toolButton(ToolType.smartSelect, Icons.auto_fix_high),
                toolButton(ToolType.aiClickSelect, Icons.smart_toy_outlined),
                toolButton(ToolType.polygonLasso, Icons.timeline),
                toolButton(ToolType.magneticLasso, Icons.gesture),
                toolButton(ToolType.brushErase, Icons.brush),
                toolButton(ToolType.restoreBrush, Icons.history_edu),
                toolButton(ToolType.aiRemoveBrush, Icons.auto_awesome),
                toolButton(ToolType.moveLayer, Icons.open_with),
                const VerticalDivider(color: Colors.white24),
                IconButton(
                  tooltip: 'Undo',
                  icon: const Icon(Icons.undo, color: Colors.white70),
                  onPressed: controller.history.canUndo ? controller.undo : null,
                ),
                IconButton(
                  tooltip: 'Redo',
                  icon: const Icon(Icons.redo, color: Colors.white70),
                  onPressed: controller.history.canRedo ? controller.redo : null,
                ),
              ],
            ),
          ),
          if (controller.tool == ToolType.brushErase ||
              controller.tool == ToolType.restoreBrush ||
              controller.tool == ToolType.aiRemoveBrush ||
              controller.tool == ToolType.aiClickSelect)
            Row(
              children: [
                const SizedBox(width: 12),
                const Icon(Icons.circle, color: Colors.white38, size: 10),
                Expanded(
                  child: Slider(
                    value: controller.brushSize,
                    min: 4,
                    max: 120,
                    activeColor: Colors.cyanAccent,
                    onChanged: (v) {
                      controller.brushSize = v;
                      controller.notifyListeners();
                    },
                  ),
                ),
                Text('${controller.brushSize.round()}px', style: const TextStyle(color: Colors.white70)),
                const SizedBox(width: 12),
              ],
            ),
          if (controller.tool == ToolType.smartSelect)
            Row(
              children: [
                const SizedBox(width: 12),
                const Text('Tolerance', style: TextStyle(color: Colors.white70, fontSize: 12)),
                Expanded(
                  child: Slider(
                    value: controller.floodFillTolerance.toDouble(),
                    min: 2,
                    max: 100,
                    activeColor: Colors.cyanAccent,
                    onChanged: (v) {
                      controller.floodFillTolerance = v.round();
                      controller.notifyListeners();
                    },
                  ),
                ),
                Text('${controller.floodFillTolerance}', style: const TextStyle(color: Colors.white70)),
                const SizedBox(width: 12),
              ],
            ),
          if (controller.tool == ToolType.aiClickSelect)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  const Text('Brush mode', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(
                          value: false,
                          label: Text('Include'),
                          icon: Icon(Icons.add_circle_outline, size: 16),
                        ),
                        ButtonSegment(
                          value: true,
                          label: Text('Exclude'),
                          icon: Icon(Icons.remove_circle_outline, size: 16),
                        ),
                      ],
                      selected: {controller.samBrushExclude},
                      onSelectionChanged: (selection) {
                        controller.samBrushExclude = selection.first;
                        controller.notifyListeners();
                      },
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}