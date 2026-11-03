# WallpaperBlendLab

M20 measurement: a 4-colour gradient wallpaper with pattern tiles under a `softLightBlendMode` compositing filter
(as `BackgroundView`/`TileControl` set it for light pattern themes), with chat bubbles moving over it, rendered offscreen
with `CARenderer` at 2x. Variants: `filter` (today), `rasterized` (`shouldRasterize` on the static background
subtree), `plain` (no filter, reference cost). Prints GPU+CPU time per frame and the pixel difference between
`filter` and `rasterized`.

    swift run -c release --package-path tools/perflab/WallpaperBlendLab
