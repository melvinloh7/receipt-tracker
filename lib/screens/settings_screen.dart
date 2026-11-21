import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../services/background.dart';
import '../services/gemini.dart';
import '../services/google_api.dart';
import '../services/google_auth.dart';
import '../services/image_pipeline.dart';
import '../services/settings_store.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

enum _Status { waiting, running, passed, failed }

/// One line of the connection test, updated live as it runs.
class _Check {
  _Check(this.name, this.run);
  final String name;
  final Future<String> Function(void Function(String note) note) run;
  _Status status = _Status.waiting;
  String detail = 'Waiting';
  DateTime? started;
  Duration? took;
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = SettingsStore();
  final _keyCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _longSideCtrl = TextEditingController();
  final _longReceiptCtrl = TextEditingController();
  final _qualityCtrl = TextEditingController();
  bool _greyscale = true;
  final _peopleCtrl = TextEditingController();
  bool _busy = false;
  String? _authError;
  List<_Check> _checks = const [];
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _keyCtrl.text = await _settings.geminiKey();
    _modelCtrl.text = await _settings.geminiModel();
    final c = await _settings.compression();
    _longSideCtrl.text = '${c.longSide}';
    _longReceiptCtrl.text = '${c.longReceiptSide}';
    _qualityCtrl.text = '${c.quality}';
    _greyscale = c.greyscale;
    _peopleCtrl.text = (await _settings.people()).where((p) => p != 'Self').join(', ');
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    _longSideCtrl.dispose();
    _longReceiptCtrl.dispose();
    _qualityCtrl.dispose();
    _peopleCtrl.dispose();
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
    await _settings.savePeople(_peopleCtrl.text.split(','));
    const d = CompressionSettings();
    await _settings.saveCompression(CompressionSettings(
      longSide: int.tryParse(_longSideCtrl.text) ?? d.longSide,
      longReceiptSide: int.tryParse(_longReceiptCtrl.text) ?? d.longReceiptSide,
      quality: (int.tryParse(_qualityCtrl.text) ?? d.quality).clamp(10, 100),
      greyscale: _greyscale,
    ));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
  }

  // Every setState is guarded: checks keep running if you leave this screen.
  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _runOne(_Check c) async {
    c.status = _Status.running;
    c.detail = 'Running';
    c.started = DateTime.now();
    _refresh();
    try {
      final result = await c.run((note) {
        if (mounted) setState(() => c.detail = note);
      });
      c.status = _Status.passed;
      c.detail = result;
    } catch (e) {
      c.status = _Status.failed;
      c.detail = e.toString();
    }
    c.took = DateTime.now().difference(c.started!);
    if (mounted) setState(() {});
  }

  Future<void> _runChecks() async {
    await _save();
    final api = GoogleApi();
    final gemini = GeminiClient(_settings);
    final checks = [
      _Check('Drive: open Receipts folder', (_) async {
        return 'Found "${await api.receiptsFolderName()}"';
      }),
      _Check('Drive: write a test file', (_) async {
        await api.driveWriteCheck();
        return 'Created and removed a test file';
      }),
      _Check('Ledger: read categories', (_) async {
        final cats = await api.readCategories();
        return '${cats.length} categories: ${cats.take(4).join(', ')}…';
      }),
      _Check('AI: reach Gemini', (_) => gemini.describeModel()),
      _Check('AI: Gemini reply', (note) async {
        final reply = await gemini.generateText(
          'Reply with the single word OK.',
          thinkingLevel: 'minimal',
          onRetry: (attempt, of) => note('Connection dropped, retry $attempt of $of'),
        );
        return 'Replied "$reply"';
      }),
    ];
    _busy = true;
    _checks = checks;
    _refresh();
    // Redraw once a second so running checks show their elapsed time.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    // All checks run at the same time; each line updates as it finishes.
    // Runs as background work, so you can switch apps; a notification tells
    // you the result if you've left the app.
    await Background.ensurePermission();
    try {
      await Background.run<List<_Check>>(
        title: 'Connection test',
        job: (report) async {
          var finished = 0;
          report('0 of ${checks.length} done', done: 0, total: checks.length);
          await Future.wait(checks.map((c) async {
            await _runOne(c);
            finished++;
            report('$finished of ${checks.length} done', done: finished, total: checks.length);
          }));
          return checks;
        },
        summary: (results) {
          final failed = results.where((c) => c.status == _Status.failed).toList();
          if (failed.isEmpty) {
            return ('Connection test passed', 'All ${results.length} checks passed');
          }
          return (
            'Connection test: ${failed.length} failed',
            failed.map((c) => c.name).join(', '),
          );
        },
      );
    } catch (_) {
      // Each check records its own error on screen.
    }
    _ticker?.cancel();
    if (mounted) setState(() => _busy = false);
  }

  Widget _numberField(TextEditingController ctrl, String label) => TextField(
        controller: ctrl,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      );

  Widget _statusIcon(_Check c) {
    switch (c.status) {
      case _Status.waiting:
        return const Icon(Icons.schedule, color: Colors.grey);
      case _Status.running:
        return const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        );
      case _Status.passed:
        return const Icon(Icons.check_circle, color: Colors.green);
      case _Status.failed:
        return Icon(Icons.error, color: Theme.of(context).colorScheme.error);
    }
  }

  String _timing(_Check c) {
    if (c.took != null) return ' · ${(c.took!.inMilliseconds / 1000).toStringAsFixed(1)}s';
    if (c.started != null) {
      return ' · ${DateTime.now().difference(c.started!).inSeconds}s';
    }
    return '';
  }

  Widget _summary() {
    final done = _checks.where((c) => c.status == _Status.passed || c.status == _Status.failed).length;
    final failed = _checks.where((c) => c.status == _Status.failed).length;
    final total = _checks.length;
    final String text;
    if (_busy) {
      text = '$done of $total done';
    } else if (failed == 0) {
      text = 'All $total checks passed';
    } else {
      text = '$failed of $total checks failed';
    }
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        // Extra bottom space so nothing sits under Android's navigation buttons.
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.of(context).viewPadding.bottom + 24,
        ),
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
          const Divider(height: 40),
          Text('People', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('Names you share bills with, so the AI spells them the same way every time.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          TextField(
            controller: _peopleCtrl,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'People (comma-separated)',
              hintText: 'Des, Wife',
              border: OutlineInputBorder(),
            ),
          ),
          const Divider(height: 40),
          Text('Receipt compression', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('Applies to receipts scanned from now on.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _numberField(_longSideCtrl, 'Long side (px)')),
            const SizedBox(width: 12),
            Expanded(child: _numberField(_longReceiptCtrl, 'Long receipts (px)')),
          ]),
          const SizedBox(height: 12),
          _numberField(_qualityCtrl, 'JPEG quality (10–100)'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Greyscale'),
            value: _greyscale,
            onChanged: (v) => setState(() => _greyscale = v),
          ),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _save, child: const Text('Save settings')),
          const Divider(height: 40),
          FilledButton.icon(
            onPressed: _busy ? null : _runChecks,
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('Run connection test'),
          ),
          if (_checks.isNotEmpty) _summary(),
          for (final c in _checks)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: _statusIcon(c),
              title: Text('${c.name}${_timing(c)}'),
              // Selectable, so an error can be copied and pasted to Claude.
              subtitle: SelectableText(c.detail),
            ),
        ],
      ),
    );
  }
}
