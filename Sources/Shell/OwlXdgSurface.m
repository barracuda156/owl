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

#import "OwlXdgSurface.h"
#import "OwlSurface.h"
#import "OwlXdgToplevel.h"
#import "xdg-shell.h"
#import <wayland-server.h>


@implementation OwlXdgSurface

static void xdg_surface_destroy(struct wl_resource *resource) {
    OwlXdgSurface *self = wl_resource_get_user_data(resource);
    [self release];
}

static void xdg_surface_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void xdg_surface_get_xdg_toplevel_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id
) {
    OwlXdgSurface *self = wl_resource_get_user_data(resource);
    struct wl_resource *xdg_toplevel_resource = wl_resource_create(
        client,
        &xdg_toplevel_interface,
        1,
        id
    );
    [[[OwlXdgToplevel alloc] initWithResource: xdg_toplevel_resource
                                      surface: self->_surface
                                   xdgSurface: self] release];
}

static void xdg_surface_ack_configure_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t serial
) {
    // TODO
}

static void xdg_surface_set_window_geometry_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height
) {
    OwlXdgSurface *self = wl_resource_get_user_data(resource);
    NSRect rect = NSMakeRect(x, y, width, height);
    [self->_surface setPendingGeometry: rect];
}

static const struct xdg_surface_interface xdg_surface_impl = {
    .destroy = xdg_surface_destroy_handler,
    .get_toplevel = xdg_surface_get_xdg_toplevel_handler,
    .ack_configure = xdg_surface_ack_configure_handler,
    .set_window_geometry = xdg_surface_set_window_geometry_handler
    // TODO
};

- (id) initWithResource: (struct wl_resource *) resource
                surface: (OwlSurface *) surface
{
    _resource = resource;
    _surface = [surface retain];
    wl_resource_set_implementation(
        resource,
        &xdg_surface_impl,
        [self retain],
        xdg_surface_destroy
    );
    return self;
}

- (void) dealloc {
    [_surface release];
    [super dealloc];
}

- (void) sendConfigure {
    struct wl_client *client = wl_resource_get_client(_resource);
    struct wl_display *display = wl_client_get_display(client);
    uint32_t serial = wl_display_next_serial(display);
    xdg_surface_send_configure(_resource, serial);
}

- (NSSize) geometrySizeForBufferSize: (NSSize) size {
    NSSize adj = [_surface geometrySizeAdjustements];
    size.width -= adj.width;
    size.height -= adj.height;
    return size;
}

@end
