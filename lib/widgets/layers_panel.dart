import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/editor_controller.dart';

class LayersPanel extends StatelessWidget {
  const LayersPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EditorController>();

    return Container(
      color: const Color(0xFF1B1B1F),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Text('Layers', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                  tooltip: 'Duplicate layer',
                  icon: const Icon(Icons.copy_all, color: Colors.white70),
                  onPressed: controller.activeLayer == null ? null : controller.duplicateActiveLayer,
                ),
                IconButton(
                  tooltip: 'Delete layer',
                  icon: const Icon(Icons.delete_outline, color: Colors.white70),
                  onPressed: controller.layers.length <= 1 ? null : controller.deleteActiveLayer,
                ),
              ],
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              itemCount: controller.layers.length,
              onReorder: (oldIndex, newIndex) {
                if (newIndex > oldIndex) newIndex -= 1;
                controller.reorderLayer(oldIndex, newIndex);
              },
              itemBuilder: (context, index) {
                // Show topmost layer first in the list (reverse visual order).
                final reversedIndex = controller.layers.length - 1 - index;
                final layer = controller.layers[reversedIndex];
                final isActive = reversedIndex == controller.activeLayerIndex;
                return Container(
                  key: ValueKey(layer.id),
                  color: isActive ? const Color(0xFF34343C) : Colors.transparent,
                  child: ListTile(
                    dense: true,
                    onTap: () => controller.selectLayer(reversedIndex),
                    leading: IconButton(
                      icon: Icon(
                        layer.visible ? Icons.visibility : Icons.visibility_off,
                        color: Colors.white70,
                        size: 20,
                      ),
                      onPressed: () => controller.toggleVisibility(reversedIndex),
                    ),
                    title: Text(
                      layer.name,
                      style: TextStyle(
                        color: isActive ? Colors.cyanAccent : Colors.white,
                        fontSize: 13,
                      ),
                    ),
                    subtitle: Slider(
                      value: layer.opacity,
                      onChanged: (v) => controller.setOpacity(reversedIndex, v),
                      activeColor: Colors.cyanAccent,
                    ),
                    trailing: const Icon(Icons.drag_handle, color: Colors.white38),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
