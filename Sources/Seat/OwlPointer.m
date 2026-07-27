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

#import "OwlPointer.h"
#import <wayland-server.h>
#import "OwlServer.h"
#import "OwlSurface.h"
#import "OwlBuffer.h"


@implementation OwlPointer

static NSMutableArray *pointers;

+ (void) initialize {
    if (pointers == nil) {
        pointers = [[NSMutableArray alloc] initWithCapacity: 1];
    }
}

+ (OwlPointer *) pointerForClient: (struct wl_client *) client {
    for (OwlPointer *pointer in pointers) {
        struct wl_resource *resource = pointer->_resource;
        if (client == wl_resource_get_client(resource)) {
            return pointer;
        }
    }
    return nil;
}

+ (void) notifyCursorSurfaceCommit: (struct wl_resource *) surfaceResource {
    /* Check if any pointer is using this surface as cursor */
    NSUInteger i, count = [pointers count];
    for (i = 0; i < count; i++) {
        OwlPointer *pointer = [pointers objectAtIndex: i];
        if (pointer->_cursorSurface == surfaceResource) {
            [pointer updateCursorFromSurface];
            [pointer applyCursor];
        }
    }
}

static void cursor_surface_destroy_notify(struct wl_listener *listener, void *data) {
    /* Get the OwlPointer from the listener using container_of pattern */
    OwlPointer *self = nil;
    for (OwlPointer *pointer in pointers) {
        if (&pointer->_cursorSurfaceDestroyListener == listener) {
            self = pointer;
            break;
        }
    }
    if (self == nil) {
        return;
    }

    /* Clear the cursor surface since it's being destroyed */
    self->_cursorSurface = NULL;
    wl_list_remove(&self->_cursorSurfaceDestroyListener.link);
    wl_list_init(&self->_cursorSurfaceDestroyListener.link);
}

- (void) updateCursorFromSurface {
    [_cursor release];
    _cursor = nil;

    if (_cursorSurface == NULL) {
        /* Hide cursor - use invisible cursor */
        NSImage *emptyImage = [[NSImage alloc] initWithSize: NSMakeSize(1, 1)];
        _cursor = [[NSCursor alloc] initWithImage: emptyImage
                                          hotSpot: NSZeroPoint];
        [emptyImage release];
        return;
    }

    /* Get the cursor surface */
    OwlSurface *surface = wl_resource_get_user_data(_cursorSurface);
    if (surface == nil) {
        _cursor = [[NSCursor arrowCursor] retain];
        return;
    }

    /* Get cursor image from the surface */
    NSImage *cursorImage = [surface createCursorImage];
    if (cursorImage == nil) {
        /* No buffer yet, use default arrow */
        _cursor = [[NSCursor arrowCursor] retain];
        return;
    }

    /* Create cursor with hotspot */
    NSPoint hotspot = NSMakePoint(_hotspotX, _hotspotY);
    _cursor = [[NSCursor alloc] initWithImage: cursorImage hotSpot: hotspot];
    [cursorImage release];
}

- (void) applyCursor {
    if (_cursor != nil) {
        [_cursor set];
    } else {
        [[NSCursor arrowCursor] set];
    }
}

// Used by wp_cursor_shape_device_v1.set_shape to switch to a named
// system cursor. Detaches any cursor surface exactly as the
// surface_resource == NULL branch of pointer_set_cursor does, then
// takes ownership of the given cursor.
- (void) setNamedCursor: (NSCursor *) cursor {
    if (_cursorSurface != NULL) {
        wl_list_remove(&_cursorSurfaceDestroyListener.link);
        wl_list_init(&_cursorSurfaceDestroyListener.link);
        _cursorSurface = NULL;
    }

    [_cursor release];
    _cursor = [cursor retain];

    [self applyCursor];
}

static void pointer_set_cursor(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t serial,
    struct wl_resource *surface_resource,
    int32_t hotspot_x,
    int32_t hotspot_y
) {
    OwlPointer *self = wl_resource_get_user_data(resource);

    /* Remove listener from old cursor surface if any */
    if (self->_cursorSurface != NULL) {
        wl_list_remove(&self->_cursorSurfaceDestroyListener.link);
        wl_list_init(&self->_cursorSurfaceDestroyListener.link);
    }

    self->_cursorSurface = surface_resource;
    self->_hotspotX = hotspot_x;
    self->_hotspotY = hotspot_y;

    if (surface_resource == NULL) {
        /* Client wants to hide cursor */
        [self->_cursor release];
        self->_cursor = nil;

        /* Create invisible cursor */
        NSImage *emptyImage = [[NSImage alloc] initWithSize: NSMakeSize(1, 1)];
        self->_cursor = [[NSCursor alloc] initWithImage: emptyImage
                                                hotSpot: NSZeroPoint];
        [emptyImage release];
    } else {
        /* Add destroy listener to new cursor surface */
        wl_resource_add_destroy_listener(
            surface_resource,
            &self->_cursorSurfaceDestroyListener
        );
        /* Cursor will be updated when surface commits */
        [self updateCursorFromSurface];
    }

    [self applyCursor];
}

static void pointer_release_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static const struct wl_pointer_interface pointer_impl = {
    .set_cursor = pointer_set_cursor,
    .release = pointer_release_handler
};

static void pointer_destroy(struct wl_resource *resource) {
    OwlPointer *self = wl_resource_get_user_data(resource);
    [pointers removeObjectIdenticalTo: self];
    [self release];
}

- (void) dealloc {
    /* Remove destroy listener if still active */
    if (_cursorSurface != NULL) {
        wl_list_remove(&_cursorSurfaceDestroyListener.link);
    }
    [_cursor release];
    [super dealloc];
}

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    _cursorSurface = NULL;
    wl_list_init(&_cursorSurfaceDestroyListener.link);
    _cursorSurfaceDestroyListener.notify = cursor_surface_destroy_notify;
    [pointers addObject: self];
    wl_resource_set_implementation(
        resource,
        &pointer_impl,
        [self retain],
        pointer_destroy
    );
    return self;
}

- (struct wl_resource *) resource {
    return _resource;
}

// Since version 5 of wl_pointer, clients group the incoming
// events by frames, and expect a frame event to terminate each
// group; without it, they may defer processing indefinitely.
- (void) sendFrame {
    if (wl_resource_get_version(_resource) >= 5) {
        wl_pointer_send_frame(_resource);
    }
}

- (void) sendEnterSurface: (OwlSurface *) surface atPoint: (NSPoint) point {
    wl_pointer_send_enter(
        _resource,
        [[OwlServer sharedServer] nextSerial],
        [surface resource],
        wl_fixed_from_double(point.x),
        wl_fixed_from_double(point.y)
    );
    [self sendFrame];

    /* Apply current cursor when entering a surface */
    [self applyCursor];
}

- (void) sendMotionAtPoint: (NSPoint) point {
    wl_pointer_send_motion(
        _resource,
        [OwlServer timestamp],
        wl_fixed_from_double(point.x),
        wl_fixed_from_double(point.y)
    );
    [self sendFrame];
}

- (void) sendLeaveSurface: (OwlSurface *) surface {
    wl_pointer_send_leave(
        _resource,
        [[OwlServer sharedServer] nextSerial],
        [surface resource]
    );
    [self sendFrame];
}

- (void) sendAxis: (enum wl_pointer_axis) axis value: (CGFloat) value {
    // The axis value is expressed in surface-local coordinate
    // units; Cocoa gives us wheel deltas in lines. Scale by
    // roughly a line height so that scrolling feels right, and
    // let version 5+ clients know the exact detent count.
    if (wl_resource_get_version(_resource) >= 5) {
        int32_t discrete = (int32_t) (value > 0 ? value + 0.5 : value - 0.5);
        if (discrete != 0) {
            wl_pointer_send_axis_discrete(_resource, axis, discrete);
        }
    }
    wl_pointer_send_axis(
        _resource,
        [OwlServer timestamp],
        axis,
        wl_fixed_from_double(value * 10.0)
    );
}

- (void) sendScrollByX: (CGFloat) deltaX byY: (CGFloat) deltaY {
    if (deltaX == 0.0 && deltaY == 0.0) {
        return;
    }

    if (deltaX != 0.0) {
        [self sendAxis: WL_POINTER_AXIS_HORIZONTAL_SCROLL value: deltaX];
    }

    if (deltaY != 0.0) {
        [self sendAxis: WL_POINTER_AXIS_VERTICAL_SCROLL value: -deltaY];
    }

    [self sendFrame];
}

- (void) sendButton: (uint32_t) button isPressed: (BOOL) isPressed {
    enum wl_pointer_button_state state = isPressed
        ? WL_POINTER_BUTTON_STATE_PRESSED
        : WL_POINTER_BUTTON_STATE_RELEASED;

    wl_pointer_send_button(
        _resource,
        [[OwlServer sharedServer] nextSerial],
        [OwlServer timestamp],
        button,
        state
    );
    [self sendFrame];
}

@end
