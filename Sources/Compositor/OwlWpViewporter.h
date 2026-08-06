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


/* Implements wp_viewporter (the stable viewporter protocol).
 *
 * A wp_viewport decouples the size of a surface from the size of
 * its buffer: the compositor scales the buffer (or a sub-rectangle
 * of it) to a client-chosen destination size. mpv's wlshm video
 * output refuses to start without it, and swayimg and GTK use it
 * opportunistically.
 */
@interface OwlWpViewporter : NSObject <OwlGlobal> {
    struct wl_resource *_resource;
}

- (id) initWithResource: (struct wl_resource *) resource;

+ (void) addGlobalToDisplay: (struct wl_display *) display;

@end


/* The crop and scale state itself lives in OwlSurfaceState, since
 * it is double-buffered surface state like any other; this object
 * validates requests and writes them into the surface's pending
 * state.
 */
@interface OwlWpViewport : NSObject {
@public
    struct wl_resource *_resource;
    // The surface this viewport crops and scales. Not retained;
    // cleared when the surface resource is destroyed, after which
    // every request except destroy raises the no_surface error.
    OwlSurface *_surface;
    struct wl_listener _surfaceDestroyListener;
}

- (id) initWithResource: (struct wl_resource *) resource
                surface: (OwlSurface *) surface;

/* The wp_viewport resource, for posting commit-time errors. */
- (struct wl_resource *) resource;

@end
