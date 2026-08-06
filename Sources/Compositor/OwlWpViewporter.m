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

#import "OwlWpViewporter.h"
#import "OwlSurface.h"
#import "viewporter.h"
#import <wayland-server.h>


@implementation OwlWpViewport

static NSMutableArray *viewports;

+ (void) initialize {
    if (viewports == nil) {
        viewports = [[NSMutableArray alloc] initWithCapacity: 1];
    }
}

static void viewport_surface_destroy_notify(
    struct wl_listener *listener,
    void *data
) {
    OwlWpViewport *self = nil;
    for (OwlWpViewport *viewport in viewports) {
        if (&viewport->_surfaceDestroyListener == listener) {
            self = viewport;
            break;
        }
    }
    if (self == nil) {
        return;
    }

    self->_surface = nil;
    wl_list_remove(&self->_surfaceDestroyListener.link);
    wl_list_init(&self->_surfaceDestroyListener.link);
}

static void viewport_destroy(struct wl_resource *resource) {
    OwlWpViewport *self = wl_resource_get_user_data(resource);
    // Destroying the viewport also removes the crop and scale
    // state from the surface, taking effect on the next commit.
    // (A no-op if the surface is already gone.)
    [self->_surface viewportWasDestroyed];
    [viewports removeObjectIdenticalTo: self];
    [self release];
}

static void viewport_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

// Returns NO (after posting the no_surface error) if the wl_surface
// this viewport was created for is gone; per the spec, every request
// except destroy is an error then.
static BOOL viewport_check_surface(
    OwlWpViewport *self,
    struct wl_resource *resource
) {
    if (self->_surface != nil) {
        return YES;
    }
    wl_resource_post_error(
        resource,
        WP_VIEWPORT_ERROR_NO_SURFACE,
        "the wl_surface of this wp_viewport was destroyed"
    );
    return NO;
}

static void viewport_set_source_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    wl_fixed_t x,
    wl_fixed_t y,
    wl_fixed_t width,
    wl_fixed_t height
) {
    OwlWpViewport *self = wl_resource_get_user_data(resource);
    if (!viewport_check_surface(self, resource)) {
        return;
    }
    if (x == wl_fixed_from_int(-1)
        && y == wl_fixed_from_int(-1)
        && width == wl_fixed_from_int(-1)
        && height == wl_fixed_from_int(-1))
    {
        [self->_surface unsetPendingViewportSource];
        return;
    }
    double source_x = wl_fixed_to_double(x);
    double source_y = wl_fixed_to_double(y);
    double source_width = wl_fixed_to_double(width);
    double source_height = wl_fixed_to_double(height);
    if (source_x < 0 || source_y < 0
        || source_width <= 0 || source_height <= 0)
    {
        wl_resource_post_error(
            resource,
            WP_VIEWPORT_ERROR_BAD_VALUE,
            "invalid source rectangle (%g, %g) %gx%g",
            source_x, source_y, source_width, source_height
        );
        return;
    }
    NSRect source = NSMakeRect(
        source_x, source_y,
        source_width, source_height
    );
    [self->_surface setPendingViewportSource: source];
}

static void viewport_set_destination_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    int32_t width,
    int32_t height
) {
    OwlWpViewport *self = wl_resource_get_user_data(resource);
    if (!viewport_check_surface(self, resource)) {
        return;
    }
    if (width == -1 && height == -1) {
        [self->_surface unsetPendingViewportDestination];
        return;
    }
    if (width <= 0 || height <= 0) {
        wl_resource_post_error(
            resource,
            WP_VIEWPORT_ERROR_BAD_VALUE,
            "invalid destination size %dx%d",
            width, height
        );
        return;
    }
    [self->_surface setPendingViewportDestination:
                        NSMakeSize(width, height)];
}

static const struct wp_viewport_interface viewport_impl = {
    .destroy = viewport_destroy_handler,
    .set_source = viewport_set_source_handler,
    .set_destination = viewport_set_destination_handler
};

- (id) initWithResource: (struct wl_resource *) resource
                surface: (OwlSurface *) surface
{
    _resource = resource;
    _surface = surface;
    [surface setViewport: self];
    _surfaceDestroyListener.notify = viewport_surface_destroy_notify;
    wl_resource_add_destroy_listener(
        [surface resource],
        &_surfaceDestroyListener
    );
    [viewports addObject: self];

    wl_resource_set_implementation(
        resource,
        &viewport_impl,
        [self retain],
        viewport_destroy
    );

    return self;
}

- (void) dealloc {
    if (_surface != nil) {
        wl_list_remove(&_surfaceDestroyListener.link);
    }
    [super dealloc];
}

- (struct wl_resource *) resource {
    return _resource;
}

@end


@implementation OwlWpViewporter

static void viewporter_destroy(struct wl_resource *resource) {
    OwlWpViewporter *self = wl_resource_get_user_data(resource);
    [self release];
}

static void viewporter_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void viewporter_get_viewport_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    struct wl_resource *surface_resource
) {
    OwlSurface *surface = wl_resource_get_user_data(surface_resource);
    if ([surface hasViewport]) {
        wl_resource_post_error(
            resource,
            WP_VIEWPORTER_ERROR_VIEWPORT_EXISTS,
            "wl_surface@%u already has a wp_viewport",
            wl_resource_get_id(surface_resource)
        );
        return;
    }

    struct wl_resource *viewport_resource = wl_resource_create(
        client,
        &wp_viewport_interface,
        wl_resource_get_version(resource),
        id
    );
    OwlWpViewport *viewport = [OwlWpViewport alloc];
    [[viewport initWithResource: viewport_resource
                        surface: surface] release];
}

static const struct wp_viewporter_interface viewporter_impl = {
    .destroy = viewporter_destroy_handler,
    .get_viewport = viewporter_get_viewport_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &viewporter_impl,
        [self retain],
        viewporter_destroy
    );
    return self;
}

static void viewporter_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &wp_viewporter_interface,
        version,
        id
    );
    [[[OwlWpViewporter alloc] initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    wl_global_create(
        display,
        &wp_viewporter_interface,
        1,
        NULL,
        viewporter_bind
    );
}

@end
