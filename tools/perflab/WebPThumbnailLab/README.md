# WebPThumbnailLab

H4 check: the static-sticker thumbnail decodes the WebP once, at the target size, instead of two full-size
decodes and redraws. `swift test --package-path tools/perflab/WebPThumbnailLab` (needs
`core-xprojects/libwebp/build/arm64/libwebp.a` from the native build).
