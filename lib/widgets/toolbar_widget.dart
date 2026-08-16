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
                toolButton(ToolType.fillBucket, Icons.format_color_fill),
                toolButton(ToolType.eyedropper, Icons.colorize),
                toolButton(ToolType.cloneStamp, Icons.copy_all_outlined),
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
              controller.tool == ToolType.aiClickSelect ||
              controller.tool == ToolType.cloneStamp)
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
                      controller.previewBrushSizeBriefly();
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
          if (controller.tool == ToolType.fillBucket || controller.tool == ToolType.eyedropper)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  const Text('Color', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: () => _pickFillColor(context, controller),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: controller.fillColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white38, width: 1.5),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (controller.tool == ToolType.eyedropper)
                    const Expanded(
                      child: Text(
                        'Tap the canvas to sample a color',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          if (controller.tool == ToolType.cloneStamp)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  Icon(
                    controller.cloneSourceAnchor == null ? Icons.location_searching : Icons.check_circle_outline,
                    color: controller.cloneSourceAnchor == null ? Colors.orangeAccent : Colors.cyanAccent,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      controller.cloneSourceAnchor == null
                          ? 'Tap a spot with matching texture to set the source'
                          : 'Drag to paint with the sampled texture',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      controller.cloneSourceAnchor = null;
                      controller.cloneSettingSource = true;
                      controller.notifyListeners();
                    },
                    icon: const Icon(Icons.my_location, size: 16),
                    label: const Text('New source'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _pickFillColor(BuildContext context, EditorController controller) async {
    const swatches = [
      Colors.white,
      Colors.black,
      Colors.red,
      Colors.orange,
      Colors.yellow,
      Colors.green,
      Colors.cyan,
      Colors.blue,
      Colors.purple,
      Colors.pink,
      Colors.brown,
      Colors.grey,
    ];
    final picked = await showDialog<Color>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Fill color'),
        content: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final c in swatches)
              GestureDetector(
                onTap: () => Navigator.pop(ctx, c),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: c,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: c == controller.fillColor ? Colors.cyanAccent : Colors.white24,
                      width: c == controller.fillColor ? 3 : 1,
                    ),
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ],
      ),
    );
    if (picked != null) {
      controller.fillColor = picked;
      controller.notifyListeners();
    }
  }
}