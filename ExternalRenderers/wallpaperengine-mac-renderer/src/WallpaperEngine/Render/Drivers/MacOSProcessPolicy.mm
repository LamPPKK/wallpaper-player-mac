#include "MacOSProcessPolicy.h"

#import <Cocoa/Cocoa.h>

void wwb_macos_hide_from_dock (void) {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
}
