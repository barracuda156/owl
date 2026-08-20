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

/* Implements zwp_keyboard_shortcuts_inhibit_manager_v1.
 *
 * Owl's only compositor shortcuts are the Command chords (menu key
 * equivalents), which OwlSurface normally keeps away from clients.
 * While a surface holds an inhibitor, its Command chords are
 * forwarded instead: Command itself becomes Super (the keymap maps
 * evdev 125 to Super_L/Mod4), and the chord keys flow as ordinary
 * key events, bypassing the menu. Inhibitors are granted
 * unconditionally: active is sent on creation and inactive never
 * is, matching the reference behavior in Hyprland's
 * ShortcutsInhibit.cpp.
 */
@interface OwlZwpKeyboardShortcutsInhibitManagerV1 : NSObject <OwlGlobal> {
    struct wl_resource *_resource;
}

- (id) initWithResource: (struct wl_resource *) resource;

+ (void) addGlobalToDisplay: (struct wl_display *) display;

/* Whether the given wl_surface currently holds an inhibitor.
 * Checked by OwlSurface at key-event time; events only reach
 * focused surfaces, so this doubles as the spec's "while the
 * surface has keyboard focus" condition. */
+ (BOOL) shortcutsInhibitedForSurfaceResource:
    (struct wl_resource *) surfaceResource;

@end
