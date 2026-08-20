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

@class OwlSurface;

/* Implements zwp_pointer_constraints_v1.
 *
 * A lock maps to CGAssociateMouseAndMouseCursorPosition(false):
 * the cursor pins in place while NSEvent deltas keep flowing, which
 * relative-pointer forwards; absolute motion is suppressed for the
 * locked surface as the spec requires. A confinement has no exact
 * macOS primitive, so it is enforced by warping the cursor back to
 * the nearest in-bounds point whenever it strays out of the
 * surface.
 *
 * Constraints activate when the surface's window becomes key (or on
 * creation if it already is) and deactivate when it resigns key or
 * the surface goes away; oneshot constraints become defunct after
 * their first deactivation. Regions are not honored: the constraint
 * area is always the whole surface.
 */
@interface OwlZwpPointerConstraintsV1 : NSObject <OwlGlobal> {
    struct wl_resource *_resource;
}

- (id) initWithResource: (struct wl_resource *) resource;

+ (void) addGlobalToDisplay: (struct wl_display *) display;

/* Whether an active lock/confinement exists for this surface;
 * consulted by OwlSurface when routing mouse events. */
+ (BOOL) hasActiveLockForSurfaceResource:
    (struct wl_resource *) surfaceResource;
+ (BOOL) hasActiveConfinementForSurfaceResource:
    (struct wl_resource *) surfaceResource;

/* Called by OwlSurface when its view lands in a window: a
 * constraint created before that has had no chance to activate,
 * and if the window is already key, no notification will fire. */
+ (void) notifySurfaceMovedToWindow: (OwlSurface *) surface;

/* Warp the hardware cursor to the given point, expressed in the
 * surface's local coordinates (top-left origin). A no-op without
 * CoreGraphics (GNUstep). */
+ (void) warpPointerToSurface: (OwlSurface *) surface
                        point: (NSPoint) point;

@end
