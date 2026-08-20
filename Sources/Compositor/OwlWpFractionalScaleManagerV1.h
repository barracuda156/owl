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

/* Implements wp_fractional_scale_manager_v1.
 *
 * The preferred scale we suggest is the backing scale factor of the
 * NSWindow the surface's view lives in (1.0 before 10.7, on GNUstep,
 * and for surfaces not yet attached to any window). Clients respond
 * by submitting a buffer of surface-size × scale and attaching a
 * wp_viewport with the destination set to the surface size, which
 * owl's viewporter then maps onto the same view frame — on a Retina
 * host the view's backing store matches the buffer pixels 1:1.
 */
@interface OwlWpFractionalScaleManagerV1 : NSObject <OwlGlobal> {
    struct wl_resource *_resource;
}

- (id) initWithResource: (struct wl_resource *) resource;

+ (void) addGlobalToDisplay: (struct wl_display *) display;

/* Called by OwlSurface when its view lands in (or leaves) a window,
 * which is when the actual backing scale first becomes known. */
+ (void) notifySurfaceMovedToWindow: (OwlSurface *) surface;

@end
