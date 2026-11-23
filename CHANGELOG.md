# Changelog

What changed in each build of the Receipts app. The newest is at the top.
Download any build from the repo's Releases page and install it over the
current app; your data stays.

Builds not listed (3–6, 13, 15, 17, 19) were repeat or failed builds with no
changes of their own.

## Build 24 · 23 Nov 2026
- Settings now shows which build you have (at the bottom).
- Each download page now lists what changed in that build.
- Added this changelog.

## Build 23 · 21 Nov 2026
- Gemini rate limits handled properly: waits when Google asks for a short
  pause, stops (instead of retrying) when the daily free allowance is used up,
  and tells you which limit was hit.
- Opening the app no longer retries receipts that failed on a quota error.
- AI reads run one at a time, so a burst of receipts doesn't hit Gemini at once.

## Build 22 · 21 Nov 2026
- Fixed "Thinking level MINIMAL is not supported": if Gemini rejects a thinking
  setting, the app retries without one.

## Build 21 · 21 Nov 2026 · Phase 3
- **Ledger sync:** every transaction is copied to the Expenses tab of the Life
  Dashboard ledger a few seconds after it changes. Deletes remove the row.
  Settings has Sync now and Restore (for a new phone).
- **Splits:** Add person (from your saved people or someone new) and Split…
  (evenly, or custom amounts with a "left to assign" counter).
- **Quick add:** log an expense without a photo, e.g. "Grab to airport 32.50
  yesterday".
- **Logged:** search; filters for dates, category, status and person; running
  total of your share.
- **Catch-up:** on opening the app, cut-off AI reads resume, no-signal failures
  retry, waiting photos upload, and the ledger syncs.
- **Duplicate warning** when another receipt has the same amount and date.
- Ledger amounts are written as numbers, so the sheet can add them up.

## Build 18 · 21 Nov 2026
- Receipts are saved as soon as you tap Read receipt or send your note, and
  show "Reading receipt…" in Logged while the AI works. You can leave the chat.
- Failed reads show "AI couldn't read it · tap to retry".
- The chat's Save button is now Done; edits are kept if you just go back.
- Photos upload once the AI has named them, so Drive gets the final name.

## Build 16 · 21 Nov 2026 · Phase 2
- **AI chat after the photo:** type a note or tap Read receipt; Gemini fills in
  date, description, category, amount, who and card last 4.
- Amber = AI guess, red = missing. Fix by tapping a field or replying in chat.
- Review screen: edit, Mark reviewed, Delete photo (keeps the transaction).
- Changing date or description renames and moves the Drive file.
- People list in Settings.

## Build 14 · 21 Nov 2026
- New **From gallery** button for screenshots and e-receipts: no edge
  detection, so they're no longer warped. Snap receipt is now camera only.

## Build 12 · 18 Nov 2026
- Fixed the scanner crashing on start (PlatformException / NullPointerException).

## Build 11 · 16 Nov 2026 · Phase 1
- Snap receipt with Google's document scanner (auto-crop and straighten).
- Compression to about 100–200 KB, upload to Drive in the background, named
  `YYYYMMDD-description.jpg` in year/month folders.
- Logged list with thumbnails; receipt view with zoom and Delete.
- Compression settings in Settings.

## Build 10 · 16 Nov 2026
- Background work with a progress notification and an alert when done, so you
  can switch apps.

## Build 9 · 16 Nov 2026
- Connection test shows live progress for each check and runs them together.

## Build 8 · 16 Nov 2026
- Fixed Gemini connections dropping: replies are streamed; added a quick
  "reach Gemini" check.

## Build 7 · 16 Nov 2026
- Retries dropped connections; Settings no longer hides text behind Android's
  buttons; error messages can be copied.

## Build 2 · 14 Nov 2026
- Google sign-in works (Web client ID added).

## Build 1 · 8 Nov 2026 · Phase 0
- First version: home screen, Google sign-in, connection test for Drive, the
  ledger and Gemini, and automatic builds.
