#pragma once

#ifdef __APPLE__

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Hides the process from the Dock, Cmd-Tab switcher, and menu bar by setting
 * NSApplicationActivationPolicyProhibited. Used for offscreen frame-sequence
 * recording so the renderer never surfaces as a foreground app.
 */
void wwb_macos_hide_from_dock (void);

#ifdef __cplusplus
}
#endif

#endif /* __APPLE__ */
