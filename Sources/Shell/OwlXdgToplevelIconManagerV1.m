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

#import "OwlXdgToplevelIconManagerV1.h"
#import "OwlXdgToplevel.h"
#import "OwlWindowWrapper.h"
#import "OwlWindow.h"
#import "OwlBuffer.h"
#import "xdg-toplevel-icon-v1.h"
#import <wayland-server.h>


/* Tracks one (buffer resource, scale) pair added to an icon, with a
 * destroy listener so a buffer dying before the icon is caught. */
@interface OwlXdgToplevelIconBufferV1 : NSObject {
@public
    struct wl_resource *_bufferResource;
    int32_t _scale;
    struct wl_listener _bufferDestroyListener;
}

@end

/* All live icon buffer entries across all icons, so the destroy
 * listener can find its owning entry the way the decoration-manager
 * pattern finds its owning decoration. */
static NSMutableArray *allIconBuffers;

@implementation OwlXdgToplevelIconBufferV1

+ (void) initialize {
    if (allIconBuffers == nil) {
        allIconBuffers = [[NSMutableArray alloc] initWithCapacity: 1];
    }
}

- (void) dealloc {
    if (_bufferResource != NULL) {
        wl_list_remove(&_bufferDestroyListener.link);
    }
    [allIconBuffers removeObjectIdenticalTo: self];
    [super dealloc];
}

@end

static void icon_buffer_destroy_notify(struct wl_listener *listener, void *data) {
    OwlXdgToplevelIconBufferV1 *entry = nil;
    for (OwlXdgToplevelIconBufferV1 *candidate in allIconBuffers) {
        if (&candidate->_bufferDestroyListener == listener) {
            entry = candidate;
            break;
        }
    }
    if (entry == nil) {
        return;
    }

    entry->_bufferResource = NULL;
    wl_list_remove(&entry->_bufferDestroyListener.link);
    wl_list_init(&entry->_bufferDestroyListener.link);
}


@interface OwlXdgToplevelIconV1 : NSObject {
@public
    struct wl_resource *_resource;
    NSMutableArray *_buffers;
}

- (id) initWithResource: (struct wl_resource *) resource;

/* Returns the OwlBuffer backing the largest still-alive buffer entry,
 * or nil if the icon has none. */
- (OwlBuffer *) largestBuffer;

@end

@implementation OwlXdgToplevelIconV1

static void icon_destroy(struct wl_resource *resource) {
    OwlXdgToplevelIconV1 *self = wl_resource_get_user_data(resource);
    [self release];
}

static void icon_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void icon_set_name_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    const char *icon_name
) {
    // No icon themes on macOS; ignore.
}

static void icon_add_buffer_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *buffer_resource,
    int32_t scale
) {
    OwlXdgToplevelIconV1 *self = wl_resource_get_user_data(resource);

    OwlXdgToplevelIconBufferV1 *entry = [OwlXdgToplevelIconBufferV1 new];
    entry->_bufferResource = buffer_resource;
    entry->_scale = scale;
    entry->_bufferDestroyListener.notify = icon_buffer_destroy_notify;
    wl_resource_add_destroy_listener(
        buffer_resource,
        &entry->_bufferDestroyListener
    );
    [allIconBuffers addObject: entry];
    [self->_buffers addObject: entry];
    [entry release];
}

static const struct xdg_toplevel_icon_v1_interface icon_impl = {
    .destroy = icon_destroy_handler,
    .set_name = icon_set_name_handler,
    .add_buffer = icon_add_buffer_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    _buffers = [NSMutableArray new];
    wl_resource_set_implementation(
        resource,
        &icon_impl,
        [self retain],
        icon_destroy
    );
    return self;
}

- (void) dealloc {
    [_buffers release];
    [super dealloc];
}

- (OwlBuffer *) largestBuffer {
    struct wl_resource *bestResource = NULL;
    int32_t bestScale = -1;

    for (OwlXdgToplevelIconBufferV1 *entry in _buffers) {
        if (entry->_bufferResource == NULL) {
            continue;
        }
        if (entry->_scale > bestScale) {
            bestScale = entry->_scale;
            bestResource = entry->_bufferResource;
        }
    }

    if (bestResource == NULL) {
        return nil;
    }
    return [OwlBuffer bufferForResource: bestResource];
}

@end


@implementation OwlXdgToplevelIconManagerV1

static void icon_manager_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void icon_manager_create_icon_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id
) {
    struct wl_resource *icon_resource = wl_resource_create(
        client,
        &xdg_toplevel_icon_v1_interface,
        wl_resource_get_version(resource),
        id
    );
    [[[OwlXdgToplevelIconV1 alloc] initWithResource: icon_resource] release];
}

static void icon_manager_set_icon_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *toplevel_resource,
    struct wl_resource *icon_resource
) {
    OwlXdgToplevel *toplevel = wl_resource_get_user_data(toplevel_resource);
    OwlWindowWrapper *wrapper = [toplevel windowWrapper];
    if (wrapper == nil) {
        return;
    }
    OwlWindow *window = [wrapper window];
    if (window == nil) {
        return;
    }

    if (icon_resource == NULL) {
        [window setMiniwindowImage: nil];
        return;
    }

    OwlXdgToplevelIconV1 *icon = wl_resource_get_user_data(icon_resource);
    OwlBuffer *buffer = [icon largestBuffer];
    if (buffer == nil) {
        [window setMiniwindowImage: nil];
        return;
    }

    [buffer invalidate];
    [window setMiniwindowImage: [buffer createNSImage]];
}

static const struct xdg_toplevel_icon_manager_v1_interface icon_manager_impl = {
    .destroy = icon_manager_destroy_handler,
    .create_icon = icon_manager_create_icon_handler,
    .set_icon = icon_manager_set_icon_handler
};

static void icon_manager_destroy(struct wl_resource *resource) {
    OwlXdgToplevelIconManagerV1 *self = wl_resource_get_user_data(resource);
    [self release];
}

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &icon_manager_impl,
        [self retain],
        icon_manager_destroy
    );

    xdg_toplevel_icon_manager_v1_send_icon_size(resource, 128);
    xdg_toplevel_icon_manager_v1_send_done(resource);

    return self;
}

static void icon_manager_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &xdg_toplevel_icon_manager_v1_interface,
        version,
        id
    );
    [[[OwlXdgToplevelIconManagerV1 alloc] initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    wl_global_create(
        display,
        &xdg_toplevel_icon_manager_v1_interface,
        1,
        NULL,
        icon_manager_bind
    );
}

@end
