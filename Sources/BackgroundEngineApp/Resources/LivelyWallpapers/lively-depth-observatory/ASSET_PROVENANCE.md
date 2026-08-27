# Depth Observatory asset provenance

`media/image.png` and `media/depth.png` were generated specifically for
Background Engine on 2026-08-27 with OpenAI's `gpt-imageg 2.0` image model.
They were not copied from Lively, Wallpaper Engine, a Workshop item, or a
stock-media library. `thumbnail.png` is a downscaled derivative of
`media/image.png`. The full-size PNGs retain their generated-media C2PA
provenance metadata.

The Background Engine contributors dedicate the pixel artwork and repository-
authored raster derivatives to the public domain under CC0 1.0. This
dedication does not alter the embedded provenance assertion or grant rights in
third-party names, marks, or metadata. See
<https://creativecommons.org/publicdomain/zero/1.0/>.

The WebGL depth-map runtime is derived from
<https://github.com/rocksdanister/depthmap-wallpaper> commit
`0a0e64ef5b1f56544899adfb909a335bfe246286`. Its original image placeholders
were not included. The runtime modifications add deterministic idle movement
for click-through macOS desktop windows, use the project-created PNG assets,
and stop the animation timer while the existing Lively pause callback reports
that playback is suspended.
