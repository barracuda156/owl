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

#import "OwlZwpRelativePointerManagerV1.h"
#import "OwlServer.h"
#import "relative-pointer-unstable-v1.h"


/* One zwp_relative_pointer_v1. Owl has a single pointer per
 * client, so relative_motion is fanned out by client match at send
 * time (as Hyprland's RelativePointer.cpp does); the wl_pointer
 * this was created for is only watched for its destruction, which
 * per the spec turns this object inert. */
@interface OwlZwpRelativePointer : NSObject {
@public
    struct wl_resource *_resource;
    struct wl_resource *_pointerResource;
    struct wl_listener _pointerDestroyListener;
}

- (id) initWithResource: (struct wl_resource *) resource
        pointerResource: (struct wl_resource *) pointerResource;

@end

@implementation OwlZwpRelativePointer

static NSMutableArray *relativePointers;

+ (void) initialize {
    if (relativePointers == nil) {
        relativePointers = [[NSMutableArray alloc] initWithCapacity: 1];
    }
}

static void relative_pointer_pointer_destroy_notify(
    struct wl_listener *listener,
    void *data
) {
    OwlZwpRelativePointer *self = nil;
    for (OwlZwpRelativePointer *relativePointer in relativePointers) {
        if (&relativePointer->_pointerDestroyListener == listener) {
            self = relativePointer;
            break;
        }
    }
    if (self == nil) {
        return;
    }

    self->_pointerResource = NULL;
    wl_list_remove(&self->_pointerDestroyListener.link);
    wl_list_init(&self->_pointerDestroyListener.link);
}

static void relative_pointer_destroy(struct wl_resource *resource) {
    OwlZwpRelativePointer *self = wl_resource_get_user_data(resource);
    [relativePointers removeObjectIdenticalTo: self];
    [self release];
}

static void relative_pointer_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static const struct zwp_relative_pointer_v1_interface relative_pointer_impl = {
    .destroy = relative_pointer_destroy_handler
};

- (id) initWithResource: (struct wl_resource *) resource
        pointerResource: (struct wl_resource *) pointerResource
{
    _resource = resource;
    _pointerResource = pointerResource;
    _pointerDestroyListener.notify = relative_pointer_pointer_destroy_notify;
    wl_resource_add_destroy_listener(
        pointerResource,
        &_pointerDestroyListener
    );
    [relativePointers addObject: self];
    wl_resource_set_implementation(
        resource,
        &relative_pointer_impl,
        [self retain],
        relative_pointer_destroy
    );
    return self;
}

- (void) dealloc {
    if (_pointerResource != NULL) {
        wl_list_remove(&_pointerDestroyListener.link);
    }
    [super dealloc];
}

@end


@implementation OwlZwpRelativePointerManagerV1

+ (void) sendRelativeMotionForClient: (struct wl_client *) client
                              deltaX: (CGFloat) deltaX
                              deltaY: (CGFloat) deltaY
{
    if (deltaX == 0.0 && deltaY == 0.0) {
        return;
    }

    // The protocol wants a 64-bit microsecond timestamp split in
    // two; derive it from the same millisecond clock every other
    // owl event uses.
    uint64_t utime = (uint64_t) [OwlServer timestamp] * 1000;
    uint32_t utime_hi = (uint32_t) (utime >> 32);
    uint32_t utime_lo = (uint32_t) (utime & 0xffffffff);
    wl_fixed_t dx = wl_fixed_from_double(deltaX);
    wl_fixed_t dy = wl_fixed_from_double(deltaY);

    for (OwlZwpRelativePointer *relativePointer in relativePointers) {
        if (wl_resource_get_client(relativePointer->_resource) != client) {
            continue;
        }
        if (relativePointer->_pointerResource == NULL) {
            // The wl_pointer this was created for is gone; the
            // object stays around but goes inert.
            continue;
        }
        zwp_relative_pointer_v1_send_relative_motion(
            relativePointer->_resource,
            utime_hi,
            utime_lo,
            dx,
            dy,
            dx,
            dy
        );
    }
}

static void relative_pointer_manager_destroy(struct wl_resource *resource) {
    OwlZwpRelativePointerManagerV1 *self = wl_resource_get_user_data(resource);
    [self release];
}

static void relative_pointer_manager_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void relative_pointer_manager_get_relative_pointer_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    struct wl_resource *pointer_resource
) {
    struct wl_resource *relative_pointer_resource = wl_resource_create(
        client,
        &zwp_relative_pointer_v1_interface,
        wl_resource_get_version(resource),
        id
    );
    OwlZwpRelativePointer *relativePointer = [OwlZwpRelativePointer alloc];
    [[relativePointer initWithResource: relative_pointer_resource
                       pointerResource: pointer_resource] release];
}

static const struct zwp_relative_pointer_manager_v1_interface
relative_pointer_manager_impl = {
    .destroy = relative_pointer_manager_destroy_handler,
    .get_relative_pointer = relative_pointer_manager_get_relative_pointer_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &relative_pointer_manager_impl,
        [self retain],
        relative_pointer_manager_destroy
    );
    return self;
}

static void relative_pointer_manager_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &zwp_relative_pointer_manager_v1_interface,
        version,
        id
    );
    OwlZwpRelativePointerManagerV1 *self =
        [OwlZwpRelativePointerManagerV1 alloc];
    [[self initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    wl_global_create(
        display,
        &zwp_relative_pointer_manager_v1_interface,
        1,
        NULL,
        relative_pointer_manager_bind
    );
}

@end
