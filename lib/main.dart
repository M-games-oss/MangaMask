import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/editor_controller.dart';
import 'screens/editor_screen.dart';

void main() {
  runApp(const MangaCutterApp());
}

class MangaCutterApp extends StatelessWidget {
  const MangaCutterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => EditorController(),
      child: MaterialApp(
        title: 'Manga Cutter',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.cyanAccent,
            brightness: Brightness.dark,
          ),
        ),
        home: const EditorScreen(),
      ),
    );
  }
}
