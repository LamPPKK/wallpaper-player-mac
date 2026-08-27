# Chromatic Fluids asset provenance

The runtime is a minimal derivative of
<https://github.com/rocksdanister/WebGL-Fluid-Simulation> tag `v6`, commit
`bd028c0b4a931c4173e77e52cb953d964e857557`. It retains only the MIT-licensed
simulation script and its small dithering texture. Background Engine removes
the installer wallpaper backgrounds, overlay/logo, font, preview, and unused
dat.GUI dependency; none of the Pexels images from the release package are
included.

The derivative adds a minimal local page, makes random splats the safe default
when macOS system audio and pointer input are unavailable, stops the animation
frame loop when the Lively pause callback fires, and supplies a reduced set of
properties that do not reference missing user-media folders.

`thumbnail.png` was generated specifically for Background Engine on
2026-08-27 with OpenAI's `gpt-imageg 2.0` image model and was not copied from
Lively or a stock-media library. Background Engine contributors dedicate the
pixel artwork to the public domain under CC0 1.0. This dedication does not
grant rights in third-party names or marks:
<https://creativecommons.org/publicdomain/zero/1.0/>.
