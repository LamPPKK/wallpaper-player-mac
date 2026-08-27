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
Only anonymous downloads are supported; if Valve rejects access, copy the
owned project from a Windows Steam installation and import that folder.

After import, select the wallpaper, choose a display and Fit, Fill, or Stretch,
then assign it. To learn about playback modes, see
<doc:supported-wallpaper-types>.
