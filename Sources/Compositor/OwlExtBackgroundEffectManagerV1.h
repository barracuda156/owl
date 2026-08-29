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

/* Implements ext_background_effect_manager_v1 over the private
 * CGSSetWindowBackgroundBlurRadius API. The blur request reduces to
 * a per-surface on/off (see the region-handling comment in the .m
 * file) and is applied to the surface's whole NSWindow, since CGS
 * blur is a window-level property, not a per-region one.
 *
 * The private symbols are resolved via dlsym, never linked, so the
 * binary loads on every platform; when they are missing (GNUstep,
 * or a macOS without them) the manager still binds but advertises
 * no capabilities, and every background-effect object is inert.
 */
@interface OwlExtBackgroundEffectManagerV1 : NSObject <OwlGlobal> {
    struct wl_resource *_resource;
}

- (id) initWithResource: (struct wl_resource *) resource;

+ (void) addGlobalToDisplay: (struct wl_display *) display;

/* Apply or remove the CGS window-level background blur for the
 * given window. A nil window is a no-op (the caller is expected to
 * retry once the surface's view is actually in a window); a no-op
 * as well when the backend failed to resolve. */
+ (void) applyBlur: (BOOL) enabled toWindow: (NSWindow *) window;

@end
