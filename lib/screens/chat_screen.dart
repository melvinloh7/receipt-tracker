import 'dart:async';

import 'package:flutter/material.dart';

import '../data/db.dart';
import '../data/draft.dart';
import '../services/background.dart';
import '../services/google_api.dart';
import '../services/image_pipeline.dart';
import '../services/receipts.dart';
import '../services/settings_store.dart';
import '../widgets/duplicate_banner.dart';
import '../widgets/expense_editor.dart';

class _Msg {
  _Msg(this.text, {this.fromUser = false, this.isError = false});
  final String text;
  final bool fromUser;
  final bool isError;
}

/// A short chat with the AI, which fills in the expense card: after a photo,
/// or with no photo at all (Quick add, when [scanPath] is null).
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.scanPath});
  final String? scanPath;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _settings = SettingsStore();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late final Future<CompressedReceipt?> _photoFuture;
  bool get _quickAdd => widget.scanPath == null;
  CompressedReceipt? _photo;
  Object? _photoError;
  List<String> _categories = SettingsStore.defaultCategories;
  List<String> _people = const ['Self'];
  ExpenseDraft? _draft;

  /// The saved receipt's id, once you've sent your first message.
  String? _id;
  bool _thinking = false;
  bool _saving = false;
  bool _dirty = false;
  late final _messages = <_Msg>[
    _Msg(_quickAdd
        ? 'Describe the expense, e.g. "Grab to airport 32.50 yesterday" or "lunch 18 with Des".'
        : 'Add a short note, e.g. "dinner at Ikea, shared with Des", or just tap Read receipt.'),
  ];

  @override
  void initState() {
    super.initState();
    _photoFuture = _compress();
    _photoFuture.ignore(); // errors are shown on screen
    _loadCategories();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<CompressedReceipt?> _compress() async {
    final path = widget.scanPath;
    if (path == null) return null;
    try {
      final photo = await compressReceipt(path, await _settings.compression());
      if (mounted) setState(() => _photo = photo);
      return photo;
    } catch (e) {
      if (mounted) setState(() => _photoError = e);
      rethrow;
    }
  }

  Future<void> _loadCategories() async {
    final cached = await _settings.categories();
    final people = await _settings.people();
    if (mounted) {
      setState(() {
        _categories = cached;
        _people = people;
      });
    }
    // Refresh from the ledger quietly; keep the cached list if offline.
    try {
      final fresh = await GoogleApi().readCategories();
      if (fresh.isNotEmpty) {
        await _settings.saveCategories(fresh);
        if (mounted) setState(() => _categories = fresh);
      }
    } catch (_) {}
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _say(_Msg m) {
    if (!mounted) return;
    setState(() => _messages.add(m));
    _scrollToEnd();
  }

  Future<void> _send([String? preset]) async {
    if (_thinking) return;
    final text = (preset ?? _input.text).trim();
    final isCorrection = _id != null && _draft != null;
    if ((isCorrection || _quickAdd) && text.isEmpty) return;
    _input.clear();
    if (text.isNotEmpty) _say(_Msg(text, fromUser: true));

    setState(() => _thinking = true);
    _scrollToEnd();
    await Background.ensurePermission();

    try {
      final ExpenseDraft? result;
      if (_id == null) {
        // First message: save the receipt now, so it shows in Logged as
        // "Reading receipt…" even if you leave this screen.
        final photo = await _photoFuture;
        final id = await Receipts.start(photo: photo, note: text);
        if (mounted) setState(() => _id = id);
        result = await Receipts.read(id);
      } else {
        // A correction: keep any edits you made on the card first.
        await _saveEdits();
        result = await Receipts.read(_id!, correction: text);
      }
      if (!mounted) return;
      if (result == null) {
        final e = await Db.instance.get(_id!);
        _say(_Msg(
          'I couldn\'t read it: ${e?.aiError ?? 'unknown error'}\n'
          'It\'s saved in Logged as "AI couldn\'t read". Fill in the card yourself, or send a message to retry.',
          isError: true,
        ));
        if (mounted && _draft == null) setState(() => _draft = ExpenseDraft());
        return;
      }
      setState(() {
        _draft = result;
        _dirty = false;
      });
      final missing = <String>[
        if (result.missingDate) 'date',
        if (result.missingCategory) 'category',
        if (result.missingAmount) 'amount',
      ];
      _say(_Msg([
        isCorrection ? 'Updated and saved.' : 'Here\'s what I found. It\'s already saved.',
        if (result.inferred.isNotEmpty) 'Amber fields are my guesses; please check them.',
        if (missing.isNotEmpty) 'Missing: ${missing.join(', ')}.',
        if (result.inferred.isEmpty && missing.isEmpty) 'Everything came straight off the receipt.',
      ].join(' ')));
    } catch (e) {
      _say(_Msg('Something went wrong: $e', isError: true));
    } finally {
      if (mounted) setState(() => _thinking = false);
    }
  }

  /// Writes card edits to the saved receipt.
  Future<void> _saveEdits() async {
    final id = _id, draft = _draft;
    if (id == null || draft == null || !_dirty) return;
    final e = await Db.instance.get(id);
    if (e == null) return;
    await Receipts.saveEdits(e, draft);
    _dirty = false;
  }

  Future<void> _done() async {
    setState(() => _saving = true);
    try {
      await _saveEdits();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_draft?.needsReview ?? true ? 'Saved as Needs review.' : 'Saved.'),
      ));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  void _showPhoto() {
    final photo = _photo;
    if (photo == null) return;
    showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(maxScale: 6, child: Image.memory(photo.full)),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: SafeArea(
                child: IconButton.filledTonal(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bubble(_Msg m) {
    final theme = Theme.of(context);
    final bg = m.fromUser
        ? theme.colorScheme.primaryContainer
        : m.isError
            ? theme.colorScheme.errorContainer
            : theme.colorScheme.surfaceContainerHighest;
    return Align(
      alignment: m.fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
        child: SelectableText(m.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final photo = _photo;
    final draft = _draft;
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _saveEdits(); // keep card edits if you just go back
      },
      child: Scaffold(
      appBar: AppBar(title: Text(_quickAdd ? 'Quick add' : 'New receipt')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                // Receipt thumbnail; tap to see it full screen.
                if (!_quickAdd)
                Center(
                  child: GestureDetector(
                    onTap: _showPhoto,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        height: 180,
                        child: _photoError != null
                            ? Center(
                                child: Text('Could not process the photo: $_photoError',
                                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
                              )
                            : photo == null
                                ? const AspectRatio(
                                    aspectRatio: 0.6,
                                    child: Center(child: CircularProgressIndicator()),
                                  )
                                : Image.memory(photo.thumb, fit: BoxFit.contain),
                      ),
                    ),
                  ),
                ),
                if (photo != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(photo.summary,
                        textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                  ),
                const SizedBox(height: 12),
                for (final m in _messages) _bubble(m),
                if (_thinking)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text('Reading the receipt. It\'s saved in Logged; you can leave this screen.'),
                      ),
                    ]),
                  ),
                if (draft == null && !_thinking && !_quickAdd)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(spacing: 8, children: [
                      ActionChip(
                        avatar: const Icon(Icons.auto_awesome, size: 18),
                        label: const Text('Read receipt'),
                        onPressed: () => _send(''),
                      ),
                    ]),
                  ),
                if (draft != null) ...[
                  const SizedBox(height: 12),
                  if (_id != null && !_thinking)
                    DuplicateBanner(key: ValueKey(draft), expenseId: _id!),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: ExpenseEditor(
                        draft: draft,
                        categories: _categories,
                        people: _people,
                        onChanged: () => setState(() => _dirty = true),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _saving || _thinking ? null : _done,
                    icon: const Icon(Icons.check),
                    label: Text(_saving
                        ? 'Saving…'
                        : draft.needsReview
                            ? 'Done (needs review)'
                            : 'Done'),
                  ),
                ],
              ],
            ),
          ),
          // Message box.
          Material(
            elevation: 3,
            child: Padding(
              padding: EdgeInsets.fromLTRB(12, 8, 8, 8 + bottomInset),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: !_thinking,
                      textCapitalization: TextCapitalization.sentences,
                      minLines: 1,
                      maxLines: 3,
                      decoration: InputDecoration(
                        hintText: draft != null
                            ? 'Correct something, e.g. "category is Family"'
                            : _quickAdd
                                ? 'e.g. Grab to airport 32.50 yesterday'
                                : 'e.g. dinner at Ikea, shared with Des',
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _thinking ? null : () => _send(),
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
    );
  }
}
