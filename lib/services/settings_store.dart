import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config.dart';

/// Settings kept in Android's encrypted storage (never in the .apk).
class SettingsStore {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _kGeminiKey = 'gemini_api_key';
  static const _kGeminiModel = 'gemini_model';

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
}
