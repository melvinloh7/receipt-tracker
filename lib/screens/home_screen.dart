import 'package:flutter/material.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../data/db.dart';
import '../services/background.dart';
import '../services/google_auth.dart';
import '../services/receipts.dart';
import 'capture_screen.dart';
import 'logged_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _needsReview = 0;

  @override
  void initState() {
    super.initState();
    Db.instance.changes.addListener(_loadCount);
    _loadCount();
    // Finish any uploads interrupted last time (e.g. no signal).
    WidgetsBinding.instance.addPostFrameCallback((_) => Receipts.uploadPending());
  }

  @override
  void dispose() {
    Db.instance.changes.removeListener(_loadCount);
    super.dispose();
  }

  Future<void> _loadCount() async {
    final n = await Db.instance.needsReviewCount();
    if (mounted) setState(() => _needsReview = n);
  }

  Future<void> _snap() async {
    await Background.ensurePermission();
    final scanner = DocumentScanner(
      options: DocumentScannerOptions(
        documentFormats: const {DocumentFormat.jpeg},
        mode: ScannerMode.full,
        pageLimit: 1,
        isGalleryImport: true,
      ),
    );
    try {
      final result = await scanner.scanDocument();
      final List<String> images = result.images ?? const [];
      if (images.isEmpty || !mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => CaptureScreen(scanPath: images.first)),
      );
    } catch (e) {
      // Closing the scanner without a scan also lands here; only show real errors.
      final text = e.toString();
      if (mounted && !text.toLowerCase().contains('cancel')) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Scanner: $text')));
      }
    } finally {
      scanner.close();
    }
  }

  void _comingSoon(String what, String phase) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$what arrives in $phase.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Receipts'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              StreamBuilder<GoogleSignInAccount?>(
                stream: GoogleAuth.instance.userChanges,
                initialData: GoogleAuth.instance.user,
                builder: (context, snap) {
                  final user = snap.data;
                  return Card(
                    child: ListTile(
                      leading: Icon(
                        user == null ? Icons.cloud_off_outlined : Icons.cloud_done_outlined,
                      ),
                      title: Text(user == null ? 'Not connected to Google' : 'Connected'),
                      subtitle: Text(user?.email ?? 'Open Settings to sign in'),
                    ),
                  );
                },
              ),
              if (_needsReview > 0)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.rate_review_outlined),
                    title: Text('$_needsReview need${_needsReview == 1 ? 's' : ''} review'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const LoggedScreen()),
                    ),
                  ),
                ),
              const Spacer(),
              _BigButton(
                icon: Icons.photo_camera_outlined,
                label: 'Snap receipt',
                onTap: _snap,
              ),
              const SizedBox(height: 16),
              _BigButton(
                icon: Icons.edit_note_outlined,
                label: 'Quick add',
                onTap: () => _comingSoon('Quick add', 'Phase 3'),
              ),
              const SizedBox(height: 16),
              _BigButton(
                icon: Icons.receipt_long_outlined,
                label: 'Logged',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LoggedScreen()),
                ),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 88,
      child: FilledButton.tonalIcon(
        onPressed: onTap,
        icon: Icon(icon, size: 32),
        label: Text(label, style: const TextStyle(fontSize: 20)),
      ),
    );
  }
}
