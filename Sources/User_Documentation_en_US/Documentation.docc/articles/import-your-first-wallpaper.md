# Import your first wallpaper

Copy a local project into the private Background Engine library and assign it
to a display.

## Overview

Open **Library**, choose **Import Folder** for a complete Wallpaper Engine
project, **Add Lively…** for a Lively Wallpaper `.zip` export or project folder,
or **Add Wallpaper File…** for standalone media. Background Engine
validates paths and symbolic links, computes a content hash, and performs an
atomic copy into `~/Library/Application Support/Background Engine`.

Lively imports must contain `LivelyInfo.json`. Background Engine normalizes
the metadata and supported controls from `LivelyProperties.json` only on a
temporary staging copy; it never edits the selected package. ZIP imports are
rejected before extraction when they contain unsafe paths, links, duplicate
canonical names, encryption, excessive expansion, or unsupported archive
features. Imported Lively content remains user-owned and is never marked for
redistribution.

For local Web packages without a `<base>` element, quoted `/path` resource and
import-map values are normalized to package-relative paths only on that staging
copy. This preserves Lively's package-root behavior without dropping Background
Engine's random loopback path token. A package with ambiguous base semantics is
left unchanged and fails closed during compatibility analysis.

For curated upstream choices, open **Lively Wallpapers**. Six reviewed Web
wallpapers can be installed from the app bundle, while Rain, Snow, Clouds,
Ferrari 458 Italia, and Music Tunnel are downloaded only after a per-wallpaper
license and compatibility confirmation. Background Engine verifies their exact
archive size and SHA-256 before using the same importer. **Browse Lively Sample
Projects…** opens Lively's broader mixed-license list in the browser; review the
project terms yourself and use **Add Lively…** rather than treating that page as
an executable catalog.

Local Lively Video, GIF/Picture, Web, and WebAudio packages use Background
Engine's existing playback paths. URL and video-stream exports accept public
HTTPS targets only and stay blocked until you explicitly enable network access
for that wallpaper. Lively Web buttons are available in the native property
editor and send a one-shot action to each active display using that exact asset
revision. WebAudio receives neutral audio data. A package that relies on
controls attached to native Video/Image playback or adding new files through a
folder dropdown remains playable with a **Limited** explanation.

You can also paste a numeric Workshop item ID or an official Steam Community
Workshop URL in **Downloads**. Confirm SteamCMD installation when prompted.
Only anonymous downloads are supported. Background Engine requests Windows
Workshop content and forces the download into its private SteamCMD library;
only an exact absolute private-path receipt is accepted for import. On Apple
Silicon, Valve's current Intel-only SteamCMD executable requires Rosetta.
Background Engine reports `rosetta_required` when it is absent and never
installs Rosetta itself. SteamCMD is launched through a private `0600`
`/usr/bin/sandbox-exec` profile that blocks writes to the user's normal Steam
directory without changing `HOME` or `CFFIXED_USER_HOME`. Apple deprecates
`sandbox-exec`, so Background Engine treats it as fail-closed defense in depth:
if isolation cannot be applied, SteamCMD is not launched and there is no
unsandboxed fallback. If Valve rejects anonymous access, copy the owned project
from a Windows Steam installation and import that folder.

After import, select the wallpaper, choose a display and Fit, Fill, or Stretch,
then assign it. To learn about playback modes, see
<doc:supported-wallpaper-types>.
