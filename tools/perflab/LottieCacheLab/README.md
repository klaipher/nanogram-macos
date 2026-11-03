# LottieCacheLab

Unit tests for the TelegramMedia frame cache and players without building ChatUI:
M29 (frame codec benchmark and round trip), M7 (tinted emoji cache key and reuse), M8 (no decoder for a finished
webm cache), H25 (GIF tile layer pool). `swift test --package-path tools/perflab/LottieCacheLab`
(needs the native libraries in `core-xprojects/*/build`).
