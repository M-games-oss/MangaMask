import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:image/image.dart' as img;

import '../services/editor_controller.dart';
import '../services/panel_detection_service.dart';
import '../widgets/layer_canvas.dart';
import '../widgets/layers_panel.dart';
import '../widgets/toolbar_widget.dart';

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  bool _panelOpen = true;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<EditorController>();

    return Scaffold(
      backgroundColor: const Color(0xFF0E0E10),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141417),
        title: const Text('Manga Cutter'),
        actions: [
          IconButton(
            tooltip: 'Undo',
            icon: const Icon(Icons.undo),
            onPressed: controller.history.canUndo ? controller.undo : null,
          ),
          IconButton(
            tooltip: 'Redo',
            icon: const Icon(Icons.redo),
            onPressed: controller.history.canRedo ? controller.redo : null,
          ),
          IconButton(
            tooltip: 'Import image',
            icon: const Icon(Icons.file_open_outlined),
            onPressed: () => _importImage(context),
          ),
          IconButton(
            tooltip: 'Auto-detect panels',
            icon: const Icon(Icons.grid_view),
            onPressed: controller.activeLayer == null ? null : () => _detectPanels(context),
          ),
          IconButton(
            tooltip: 'AI backend settings',
            icon: const Icon(Icons.settings_input_antenna),
            onPressed: () => _showBackendSettings(context),
          ),
          IconButton(
            tooltip: 'Export',
            icon: const Icon(Icons.ios_share),
            onPressed: controller.activeLayer == null ? null : () => _export(context),
          ),
          IconButton(
            tooltip: 'Toggle layers panel',
            icon: Icon(_panelOpen ? Icons.layers : Icons.layers_outlined),
            onPressed: () => setState(() => _panelOpen = !_panelOpen),
          ),
        ],
      ),
      body: controller.layers.isEmpty
          ? _EmptyState(onImport: () => _importImage(context))
          : Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      const ToolbarWidget(),
                      const Expanded(child: LayerCanvas()),
                    ],
                  ),
                ),
                if (_panelOpen) const SizedBox(width: 240, child: LayersPanel()),
              ],
            ),
    );
  }

  Future<void> _importImage(BuildContext context) async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final bytes = await File(file.path).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return;
    if (!context.mounted) return;
    context.read<EditorController>().loadBaseImage(decoded.convert(numChannels: 4));
  }

  Future<void> _detectPanels(BuildContext context) async {
    final controller = context.read<EditorController>();
    final active = controller.activeLayer;
    if (active == null) return;

    final panels = PanelDetectionService.detectPanels(active.pixels);
    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1B1B1F),
      builder: (ctx) => ListView(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Detected Panels', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
          if (panels.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No panels found — try a full manga page image.', style: TextStyle(color: Colors.white70)),
            ),
          for (var i = 0; i < panels.length; i++)
            ListTile(
              title: Text('Panel ${i + 1}', style: const TextStyle(color: Colors.white)),
              subtitle: Text('${panels[i].width}×${panels[i].height}px', style: const TextStyle(color: Colors.white54)),
              trailing: const Icon(Icons.crop, color: Colors.cyanAccent),
              onTap: () {
                final p = panels[i];
                final cropped = img.copyCrop(active.pixels, x: p.x, y: p.y, width: p.width, height: p.height);
                controller.loadBaseImage(cropped);
                Navigator.pop(ctx);
              },
            ),
        ],
      ),
    );
  }

  void _showBackendSettings(BuildContext context) {
    final controller = context.read<EditorController>();
    final samCtrl = TextEditingController(text: controller.samBackendUrl);
    final inpaintCtrl = TextEditingController(text: controller.inpaintBackendUrl);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('AI Backend'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Point these at your deployed backend (see backend/README.md) to enable '
              'SAM click-select and the AI Remove brush. Everything else works fully offline.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(controller: samCtrl, decoration: const InputDecoration(labelText: 'SAM backend URL')),
            TextField(controller: inpaintCtrl, decoration: const InputDecoration(labelText: 'Inpainting backend URL')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              controller.samBackendUrl = samCtrl.text.trim();
              controller.inpaintBackendUrl = inpaintCtrl.text.trim();
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _export(BuildContext context) async {
    final controller = context.read<EditorController>();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1B1B1F),
      builder: (ctx) => ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.layers, color: Colors.cyanAccent),
            title: const Text('Export flattened PNG', style: TextStyle(color: Colors.white)),
            onTap: () {
              final flattened = controller.exportFlattened();
              Navigator.pop(ctx);
              _shareImage(context, flattened, 'manga_export.png');
            },
          ),
          for (var i = 0; i < controller.layers.length; i++)
            ListTile(
              leading: const Icon(Icons.image_outlined, color: Colors.white70),
              title: Text('Export "${controller.layers[i].name}" only', style: const TextStyle(color: Colors.white)),
              onTap: () {
                final layerImg = controller.exportLayer(i);
                Navigator.pop(ctx);
                _shareImage(context, layerImg, '${controller.layers[i].name}.png');
              },
            ),
        ],
      ),
    );
  }

  Future<void> _shareImage(BuildContext context, img.Image image, String filename) async {
    final bytes = img.encodePng(image);
    // Hook up share_plus / path_provider here to save or share `bytes`.
    // Kept minimal so this compiles without extra platform setup out of the box.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$filename ready (${(bytes.length / 1024).round()} KB) — wire up Share/Save in _shareImage().')),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onImport});
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.content_cut, size: 64, color: Colors.white24),
          const SizedBox(height: 16),
          const Text('Import a manga panel or character to begin', style: TextStyle(color: Colors.white54)),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: onImport,
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Import Image'),
          ),
        ],
      ),
    );
  }
}