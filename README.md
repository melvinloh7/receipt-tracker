# Receipt Tracker

Mel's Android receipt and expense tracker for the Life Dashboard. Spec: https://claude.ai/artifact/LxRjbf52qUjKAWjJLUDfWg

## How builds work

Every push to `main` runs GitHub Actions, which builds a signed `receipt-tracker.apk`
and publishes it under **Releases**. Open that release on your phone, download the .apk
and install it. Later builds install over the top, keeping your data, because they are
signed with the same key.

- Android project files are generated during the build (`flutter create`), so only `lib/`
  and `pubspec.yaml` are kept in the repo.
- Signing key: `android-signing/receipts.jks` (alias `receipts`). Don't replace it, or
  Android will refuse to update the installed app and Google sign-in will stop working.
  SHA-1: `42:0A:72:06:07:1A:DB:BB:6A:95:A1:8D:51:9E:1B:FE:BA:E8:56:04`
- Package name: `com.mayerloh.receipt_tracker`

## Configuration

- `lib/config.dart`: ledger ID, Receipts folder ID, Web OAuth client ID.
- The Gemini API key is typed into the app's Settings and stored in Android's encrypted
  storage. It is never stored in the repo.

## Status

- Phase 0 (setup): sign-in, connection test, automatic builds
