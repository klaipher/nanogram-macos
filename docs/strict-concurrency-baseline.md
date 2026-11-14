# Strict concurrency baseline (MAC-DESIGN-1, phase 1)

Packages with `StrictConcurrency` enabled as warnings (tools-version 5.9, language mode 5, no `treatAllWarnings(as: .error)`):

| Package | Warnings baseline |
|---|---|
| AppAnalytics | not measured |
| AudioPlayerCore | not measured |
| CrashReports | not measured |
| CallVideoLayer | not measured |

Already in Swift 6 language mode: LocalAudioTranscription, ChatAppIntents (and the other six v6 packages).

Measure per package with `tools/dev/tg warnings` and fill the table; phase 2 moves a package to `swiftLanguageModes: [.v6]` at zero warnings. Packages depending on Postbox or SSignalKit stay on mode 5 until the shared core is annotated.
