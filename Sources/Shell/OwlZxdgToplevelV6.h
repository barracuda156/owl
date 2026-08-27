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

#import "OwlSurface.h"
#import "OwlWindowWrapper.h"
#import <Cocoa/Cocoa.h>
#import <wayland-server.h>

@class OwlZxdgSurfaceV6;

@interface OwlZxdgToplevelV6 : NSObject<OwlSurfaceRole, NSWindowDelegate> {
    struct wl_resource *_resource;
    OwlSurface *_surface;
    OwlZxdgSurfaceV6 *_xdgSurface;
    BOOL _configured;
    BOOL _activated, _fullscreen, _resizing, _maximized;
    BOOL _destroying;
    OwlWindowWrapper *_window;
    // set_min_size / set_max_size are double-buffered (applied in
    // -update, at commit); a width or height of 0 means "no limit
    // on that axis" per spec.
    NSSize _minSize, _maxSize;
    // set_parent bookkeeping; see the stable xdg_toplevel's
    // matching ivars for the ownership/lifetime rationale.
    OwlZxdgToplevelV6 *_parent;
    struct wl_listener _parentDestroyListener;
}

- (id) initWithResource: (struct wl_resource *) resource
                surface: (OwlSurface *) surface
             xdgSurface: (OwlZxdgSurfaceV6 *) xdgSurface;

- (void) sendConfigureWithSize: (NSSize) size;

- (void) attachToParent;
- (void) detachFromParent;

@end
