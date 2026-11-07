import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../services/google_auth.dart';
import 'settings_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  void _comingSoon(BuildContext context, String what, String phase) {
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
              const Spacer(),
              _BigButton(
                icon: Icons.photo_camera_outlined,
                label: 'Snap receipt',
                onTap: () => _comingSoon(context, 'Receipt capture', 'Phase 1'),
              ),
              const SizedBox(height: 16),
              _BigButton(
                icon: Icons.edit_note_outlined,
                label: 'Quick add',
                onTap: () => _comingSoon(context, 'Quick add', 'Phase 3'),
              ),
              const SizedBox(height: 16),
              _BigButton(
                icon: Icons.receipt_long_outlined,
                label: 'Logged',
                onTap: () => _comingSoon(context, 'The Logged list', 'Phase 1'),
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
