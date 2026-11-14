# Mercurygram port: Mac coverage (spec section 9)

Mirror of the Android table (`docs/nanogram/mercurygram-port.md` there). Source: `forks/research/mercurygram-analysis.md`
(`diff:desktop`, `diff:android`, evaluation, review). Mercurygram Android is GPL-2.0, mdesktop is GPLv3-or-later. Nothing
was copied; the Mac reimplements behaviour from the descriptions. Not built or run. "Checked" means a code check of the
Mac or the shared core; "judged" means decided from the architecture (Qt, Android Java/C++) without a line-by-line audit.

Excluded by earlier owner decisions (not in this table): PFS key ladder, CDN refusal, local-only drafts, link previews off,
global search off, Premium and ads changes, Tor, GMS removal, UnifiedPush, LTO and ICF removal.

| Item (Mercurygram commit) | Status on Mac | Reason |
|---|---|---|
| mdesktop: admin log back button use-after-free (d63e548bc) | not applicable | Qt `FixedBar`; AppKit controllers do not destroy the button in its own click |
| mdesktop: export `-Wtype-limits` on unsigned char (3fc17a47f) | not applicable | C++ build fix |
| mdesktop: collapsed community members must not match Groups/Channels folders (f5b5275a4) | already had | checked: `chatListFilterPredicate` in `TelegramUtils` matches a `TelegramCommunity` by its linked peers' categories (`communityFilterCategories`) |
| mdesktop: skip the folder slide animation when the list has no area (32dce90e0) | not applicable | Qt snapshot code |
| mdesktop: submenu windows swallow clicks on Windows (d9365a4a2) | not applicable | Windows and Qt 6.10 only |
| Search operators (2b77cb2a5) | ported (feature, section 7) | `NanogramRuntime/SearchOperators`, `ChatController` |
| Tracking-parameter strip and Telegram link confirm (b469f4644 and others) | ported (feature, section 7) | `NanogramRuntime/LinkHygiene`, `InAppLinks.swift` |
| Android: push latch (28fda5a3c) | not applicable | Android `CountDownLatch`; the Mac wakes through APNs and `SharedWakeupManager` |
| Android: livestream null audio decoder context crash (1c9dcb6fd, tgcalls patch) | present, not fixed here | checked: shared tgcalls `AudioStreamingPartPersistentDecoder::decode` dereferences `_codecContext`, which is null after a failed `avcodec_open2`. The fix (return -1 when null) belongs in the tgcalls fork and must land for iOS and Mac with the same pin (see `docs/shared`); left to the main session |
| Android: TL legacy `readParams` (81011faf9) | not applicable | checked in the review: TelegramApi is generated, no legacy layer classes |
| Android: Google DoH for proxy hostnames | already had | checked in the review: `MTDNS.resolveHostnameUniversal` is native only; backup-config DoH stays like iOS |
| Android: large-account slowdowns, badge recount per deleted message (b1274170f) | not applicable | judged: Postbox keeps incremental unread counters; there is no recount on delete |
| Android: media I/O remainder (793d5745a) | not applicable | judged: Java `FileLoadOperation` and `ImageLoader`; the Mac has its own fetch manager |
| Android: notification trio, Android 16 heads-up, sound reset, permission prompt (231015942, ede78cac5, fd3d55126) | not applicable | Android notification channels |
| Android: live location "until stopped" (a2d04746f) | not applicable | judged: Android `LocationManager` replacement of Fused Location; the core's live location period is server-side. Not tested on the Mac |
| Android: secret-chat delete for everyone (flush before discard) | not applicable | judged: Android `SecretChatHelper`; the Swift core queues `deleteMessages` secret operations per message. Not tested against a second client |
| Android: pin limit double counting on folder tabs | not applicable | judged: Android tab counters |
| Android: memory leaks (observers, adapters, Bulletin ...) | not applicable | Android view lifecycle |
| Android: dice sticker cache restamping | not verified | Mac has a `DiceCache` package; the Android defect description is too short to map, nothing found to port |
| Android: crash pack (deleted-user profile, ownership transfer, forward picker, video cover decode, recycled bitmap) | not applicable | Android UI and bitmap code |
| Android: photo crop from source, motion-photo bytes, caption follows photo (e7019b3e8 ...) | not applicable | judged: Android editor and `SendMessagesHelper`; the Mac photo editor and send path differ. Not compared |
| Android: proxy hostname resolve and IPv6 in `ConnectionSocket` (d7f19a657) | not applicable | Android tgnet C++; the Mac uses MtProtoKit and the Rust engine |
