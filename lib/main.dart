import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/google_auth.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await GoogleAuth.instance.init();
  } catch (_) {
    // Sign-in setup problems are shown in Settings; the app still opens.
  }
  runApp(const ReceiptTrackerApp());
}

class ReceiptTrackerApp extends StatelessWidget {
  const ReceiptTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Receipts',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
