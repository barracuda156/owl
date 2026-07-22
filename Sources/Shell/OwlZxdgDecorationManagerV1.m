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

#import "OwlZxdgDecorationManagerV1.h"
#import "OwlXdgToplevel.h"
#import "xdg-decoration-unstable-v1.h"
#import <wayland-server.h>


/* The per-toplevel decoration object. */
@interface OwlZxdgToplevelDecorationV1 : NSObject {
@public
    struct wl_resource *_resource;
    struct wl_resource *_toplevelResource;
    struct wl_listener _toplevelDestroyListener;
}

- (id) initWithResource: (struct wl_resource *) resource
       toplevelResource: (struct wl_resource *) toplevelResource;

@end

@implementation OwlZxdgToplevelDecorationV1

static NSMutableArray *decorations;

+ (void) initialize {
    if (decorations == nil) {
        decorations = [[NSMutableArray alloc] initWithCapacity: 1];
    }
}

static void toplevel_destroy_notify(struct wl_listener *listener, void *data) {
    OwlZxdgToplevelDecorationV1 *self = nil;
    for (OwlZxdgToplevelDecorationV1 *decoration in decorations) {
        if (&decoration->_toplevelDestroyListener == listener) {
            self = decoration;
            break;
        }
    }
    if (self == nil) {
        return;
    }

    self->_toplevelResource = NULL;
    wl_list_remove(&self->_toplevelDestroyListener.link);
    wl_list_init(&self->_toplevelDestroyListener.link);
}

- (void) sendConfigure {
    zxdg_toplevel_decoration_v1_send_configure(
        _resource,
        ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE
    );

    // Per the protocol, an xdg_surface.configure should follow
    // so that the client has something to ack.
    if (_toplevelResource != NULL) {
        OwlXdgToplevel *toplevel =
            wl_resource_get_user_data(_toplevelResource);
        [toplevel sendConfigureWithSize: NSZeroSize];
    }
}

static void toplevel_decoration_destroy(struct wl_resource *resource) {
    OwlZxdgToplevelDecorationV1 *self = wl_resource_get_user_data(resource);
    [decorations removeObjectIdenticalTo: self];
    [self release];
}

static void toplevel_decoration_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void toplevel_decoration_set_mode_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t mode
) {
    // Whatever the client prefers, we always decorate
    // server-side; tell it so.
    OwlZxdgToplevelDecorationV1 *self = wl_resource_get_user_data(resource);
    [self sendConfigure];
}

static void toplevel_decoration_unset_mode_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    OwlZxdgToplevelDecorationV1 *self = wl_resource_get_user_data(resource);
    [self sendConfigure];
}

static const struct zxdg_toplevel_decoration_v1_interface
toplevel_decoration_impl = {
    .destroy = toplevel_decoration_destroy_handler,
    .set_mode = toplevel_decoration_set_mode_handler,
    .unset_mode = toplevel_decoration_unset_mode_handler
};

- (id) initWithResource: (struct wl_resource *) resource
       toplevelResource: (struct wl_resource *) toplevelResource
{
    _resource = resource;
    _toplevelResource = toplevelResource;
    _toplevelDestroyListener.notify = toplevel_destroy_notify;
    wl_resource_add_destroy_listener(
        toplevelResource,
        &_toplevelDestroyListener
    );
    [decorations addObject: self];

    wl_resource_set_implementation(
        resource,
        &toplevel_decoration_impl,
        [self retain],
        toplevel_decoration_destroy
    );

    // Announce the effective mode right away; the initial
    // xdg_surface.configure will follow from the client's first
    // commit as usual.
    zxdg_toplevel_decoration_v1_send_configure(
        resource,
        ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE
    );

    return self;
}

- (void) dealloc {
    if (_toplevelResource != NULL) {
        wl_list_remove(&_toplevelDestroyListener.link);
    }
    [super dealloc];
}

@end


@implementation OwlZxdgDecorationManagerV1

static void decoration_manager_destroy(struct wl_resource *resource) {
    OwlZxdgDecorationManagerV1 *self = wl_resource_get_user_data(resource);
    [self release];
}

static void decoration_manager_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void decoration_manager_get_toplevel_decoration_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    struct wl_resource *toplevel_resource
) {
    struct wl_resource *decoration_resource = wl_resource_create(
        client,
        &zxdg_toplevel_decoration_v1_interface,
        wl_resource_get_version(resource),
        id
    );
    OwlZxdgToplevelDecorationV1 *decoration = [OwlZxdgToplevelDecorationV1 alloc];
    [[decoration initWithResource: decoration_resource
                 toplevelResource: toplevel_resource] release];
}

static const struct zxdg_decoration_manager_v1_interface
decoration_manager_impl = {
    .destroy = decoration_manager_destroy_handler,
    .get_toplevel_decoration = decoration_manager_get_toplevel_decoration_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &decoration_manager_impl,
        [self retain],
        decoration_manager_destroy
    );
    return self;
}

static void decoration_manager_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &zxdg_decoration_manager_v1_interface,
        version,
        id
    );
    [[[OwlZxdgDecorationManagerV1 alloc] initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    wl_global_create(
        display,
        &zxdg_decoration_manager_v1_interface,
        1,
        NULL,
        decoration_manager_bind
    );
}

@end
