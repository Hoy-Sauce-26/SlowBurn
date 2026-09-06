import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/home_shell.dart';
import 'services/database.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Must run before any database is opened: sqflite ships a mobile
  // implementation only, and this is what reaches macOS, Windows and Linux.
  Database.initialiseForPlatform();
  runApp(const ProviderScope(child: SlowBurnApp()));
}

class SlowBurnApp extends StatelessWidget {
  const SlowBurnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Slow Burn',
      debugShowCheckedModeBanner: false,
      theme: lightTheme(),
      darkTheme: darkTheme(),
      home: const HomeShell(),
    );
  }
}
