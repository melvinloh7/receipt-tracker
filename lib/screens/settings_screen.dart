import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../services/gemini.dart';
import '../services/google_api.dart';
import '../services/google_auth.dart';
import '../services/settings_store.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _CheckResult {
  _CheckResult(this.name, this.ok, this.detail);
  final String name;
  final bool ok;
  final String detail;
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = SettingsStore();
  final _keyCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  bool _busy = false;
  String? _authError;
  List<_CheckResult> _results = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _keyCtrl.text = await _settings.geminiKey();
    _modelCtrl.text = await _settings.geminiModel();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _authError = null;
    });
    try {
      await GoogleAuth.instance.signIn();
    } catch (e) {
      _authError = e.toString();
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _signOut() async {
    await GoogleAuth.instance.signOut();
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    await _settings.save(geminiKey: _keyCtrl.text, geminiModel: _modelCtrl.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
  }

  Future<_CheckResult> _check(String name, Future<String> Function() run) async {
    try {
      return _CheckResult(name, true, await run());
    } catch (e) {
      return _CheckResult(name, false, e.toString());
    }
  }

  Future<void> _runChecks() async {
    await _save();
    setState(() {
      _busy = true;
      _results = const [];
    });
    final api = GoogleApi();
    final gemini = GeminiClient(_settings);
    final results = <_CheckResult>[
      await _check('Drive: open Receipts folder', () async {
        return 'Found "${await api.receiptsFolderName()}"';
      }),
      await _check('Drive: write a test file', () async {
        await api.driveWriteCheck();
        return 'Created and removed a test file';
      }),
      await _check('Ledger: read categories', () async {
        final cats = await api.readCategories();
        return '${cats.length} categories: ${cats.take(4).join(', ')}…';
      }),
      await _check('AI: Gemini reply', () async {
        final reply = await gemini.generateText('Reply with the single word OK.');
        return 'Replied "$reply"';
      }),
    ];
    if (mounted) {
      setState(() {
        _results = results;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Google account', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          StreamBuilder<GoogleSignInAccount?>(
            stream: GoogleAuth.instance.userChanges,
            initialData: GoogleAuth.instance.user,
            builder: (context, snap) {
              final user = snap.data;
              if (user == null) {
                return FilledButton.icon(
                  onPressed: _busy ? null : _signIn,
                  icon: const Icon(Icons.login),
                  label: const Text('Sign in with Google'),
                );
              }
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.account_circle_outlined),
                title: Text(user.email),
                trailing: TextButton(onPressed: _signOut, child: const Text('Sign out')),
              );
            },
          ),
          if (_authError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_authError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const Divider(height: 40),
          Text('AI', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _keyCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Gemini API key',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _modelCtrl,
            decoration: const InputDecoration(
              labelText: 'Model',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _save, child: const Text('Save')),
          const Divider(height: 40),
          FilledButton.icon(
            onPressed: _busy ? null : _runChecks,
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('Run connection test'),
          ),
          if (_busy) const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
          for (final r in _results)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                r.ok ? Icons.check_circle : Icons.error,
                color: r.ok ? Colors.green : Theme.of(context).colorScheme.error,
              ),
              title: Text(r.name),
              subtitle: Text(r.detail),
            ),
        ],
      ),
    );
  }
}
