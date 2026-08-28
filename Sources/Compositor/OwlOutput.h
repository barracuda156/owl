/* This file is part of Owl.
 *
 * Copyright © 2019-2021 Sergey Bugaev <bugaevc@gmail.com>
 *
 * Owl is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published
 * by the Free Software Foundation, either version 3 of the License,
 * or (at your option) any later version.
 *
 * Owl is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Owl.  If not, see <http://www.gnu.org/licenses/>.
 */

#import "OwlGlobal.h"
#import <Cocoa/Cocoa.h>
#import <wayland-server.h>


@interface OwlOutput : NSObject <OwlGlobal> {
    struct wl_resource *_resource;
    NSScreen *_screen;
    uint32_t _displayID;
}

- (id) initWithResource: (struct wl_resource *) resource
                 screen: (NSScreen *) screen
              displayID: (uint32_t) displayID;

- (NSScreen *) screen;
- (struct wl_resource *) resource;
- (struct wl_client *) client;
- (uint32_t) displayID;

// Re-resolve this output's screen to the live NSScreen instance for
// its display (AppKit may hand out a fresh NSScreen after a display
// reconfiguration, making a retained one stale for geometry) and
// resend the geometry/mode/scale/name/description burst, ending in
// wl_output.done. Called for a surviving display whose geometry
// changed.
- (void) refresh;

+ (void) addGlobalToDisplay: (struct wl_display *) display;

// Fan -refresh over every live OwlOutput bound to displayID.
+ (void) refreshDisplayID: (uint32_t) displayID;

// Every live OwlOutput a given client has bound (a client may bind
// wl_output more than once).
+ (NSArray *) liveOutputsForClient: (struct wl_client *) client;

// The stable identity of a screen: CGDirectDisplayID on Apple (via
// NSScreenNumber), or the screen's index in [NSScreen screens] on
// GNUstep, which has no NSScreenNumber -- hot-plug is dead code
// there, so the index only needs to be self-consistent within a run.
+ (uint32_t) displayIDForScreen: (NSScreen *) screen;

// Resolve the live NSScreen for a display ID; nil if that display is
// no longer present in [NSScreen screens].
+ (NSScreen *) screenForDisplayID: (uint32_t) displayID;

@end
