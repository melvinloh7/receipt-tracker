import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config.dart';
import 'image_pipeline.dart';

/// Settings kept in Android's encrypted storage (never in the .apk).
class SettingsStore {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _kGeminiKey = 'gemini_api_key';
  static const _kGeminiModel = 'gemini_model';
  static const _kLongSide = 'compress_long_side';
  static const _kLongReceiptSide = 'compress_long_receipt_side';
  static const _kQuality = 'compress_quality';
  static const _kGreyscale = 'compress_greyscale';
  static const _kCategories = 'categories_cache';
  static const _kPeople = 'people';

  /// Used until the ledger's Categories tab has been read once.
  static const defaultCategories = [
    'Dining', 'Groceries', 'Transport', 'Family', 'Sophie', 'Household', 'Helper',
    'Health', 'Shopping', 'Travel', 'Bills & Utilities', 'Entertainment', 'Gifts', 'Others',
  ];

  Future<String> geminiKey() async => await _storage.read(key: _kGeminiKey) ?? '';

  Future<String> geminiModel() async =>
      await _storage.read(key: _kGeminiModel) ?? AppConfig.defaultGeminiModel;

  Future<void> save({required String geminiKey, required String geminiModel}) async {
    await _storage.write(key: _kGeminiKey, value: geminiKey.trim());
    await _storage.write(
      key: _kGeminiModel,
      value: geminiModel.trim().isEmpty ? AppConfig.defaultGeminiModel : geminiModel.trim(),
    );
  }

  Future<CompressionSettings> compression() async {
    const d = CompressionSettings();
    int readInt(String? v, int fallback) => int.tryParse(v ?? '') ?? fallback;
    return CompressionSettings(
      longSide: readInt(await _storage.read(key: _kLongSide), d.longSide),
      longReceiptSide: readInt(await _storage.read(key: _kLongReceiptSide), d.longReceiptSide),
      quality: readInt(await _storage.read(key: _kQuality), d.quality),
      greyscale: (await _storage.read(key: _kGreyscale) ?? '${d.greyscale}') == 'true',
    );
  }

  Future<void> saveCompression(CompressionSettings s) async {
    await _storage.write(key: _kLongSide, value: '${s.longSide}');
    await _storage.write(key: _kLongReceiptSide, value: '${s.longReceiptSide}');
    await _storage.write(key: _kQuality, value: '${s.quality}');
    await _storage.write(key: _kGreyscale, value: '${s.greyscale}');
  }

  static List<String> _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List).map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Your categories (a copy of the ledger's Categories tab, refreshed on start).
  Future<List<String>> categories() async {
    final cached = _decodeList(await _storage.read(key: _kCategories));
    return cached.isEmpty ? defaultCategories : cached;
  }

  Future<void> saveCategories(List<String> list) async {
    if (list.isEmpty) return;
    await _storage.write(key: _kCategories, value: jsonEncode(list));
  }

  /// People you share bills with, "Self" first.
  Future<List<String>> people() async {
    final list = _decodeList(await _storage.read(key: _kPeople));
    final out = ['Self', ...list.where((p) => p.toLowerCase() != 'self')];
    return out;
  }

  Future<void> savePeople(List<String> list) async {
    final clean = <String>[];
    for (final p in list) {
      final name = p.trim();
      if (name.isEmpty || name.toLowerCase() == 'self') continue;
      if (!clean.any((c) => c.toLowerCase() == name.toLowerCase())) clean.add(name);
    }
    await _storage.write(key: _kPeople, value: jsonEncode(clean));
  }
}
