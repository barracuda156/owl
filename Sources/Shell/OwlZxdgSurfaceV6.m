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

#import "OwlZxdgSurfaceV6.h"
#import "OwlSurface.h"
#import "OwlZxdgToplevelV6.h"
#import "xdg-shell-unstable-v6.h"
#import <wayland-server.h>


@implementation OwlZxdgSurfaceV6

static void xdg_surface_v6_destroy(struct wl_resource *resource) {
    OwlZxdgSurfaceV6 *self = wl_resource_get_user_data(resource);
    [self release];
}

static void xdg_surface_v6_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void xdg_surface_v6_get_xdg_toplevel_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id
) {
    OwlZxdgSurfaceV6 *self = wl_resource_get_user_data(resource);
    // NULL rather than nil: the "id" parameter shadows the type.
    if ([self->_surface role] != NULL) {
        wl_resource_post_error(
            resource,
            ZXDG_SURFACE_V6_ERROR_ALREADY_CONSTRUCTED,
            "the surface already has a role"
        );
        return;
    }
    struct wl_resource *xdg_toplevel_resource = wl_resource_create(
        client,
        &zxdg_toplevel_v6_interface,
        1,
        id
    );
    [[[OwlZxdgToplevelV6 alloc] initWithResource: xdg_toplevel_resource
                                         surface: self->_surface
                                      xdgSurface: self] release];
}

static void xdg_surface_v6_ack_configure_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t serial
) {
    // TODO
}

/* Stub handlers for zxdg_popup_v6 */
static void xdg_popup_v6_destroy(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}
static void xdg_popup_v6_grab(struct wl_client *client, struct wl_resource *resource,
    struct wl_resource *seat, uint32_t serial) { /* stub */ }

static const struct zxdg_popup_v6_interface xdg_popup_v6_impl = {
    .destroy = xdg_popup_v6_destroy,
    .grab = xdg_popup_v6_grab
};

static void xdg_popup_v6_resource_destroy(struct wl_resource *resource) {
    /* Nothing to clean up for stub */
}

static void xdg_surface_v6_get_popup_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    struct wl_resource *parent_resource,
    struct wl_resource *positioner_resource
) {
    /* TODO: Implement popup windows properly */
    /* For now, create a stub popup that does nothing */
    struct wl_resource *popup_resource = wl_resource_create(
        client,
        &zxdg_popup_v6_interface,
        1,
        id
    );
    wl_resource_set_implementation(popup_resource, &xdg_popup_v6_impl, NULL, xdg_popup_v6_resource_destroy);

    /* Send popup_done immediately to tell client popup was dismissed */
    zxdg_popup_v6_send_popup_done(popup_resource);
}

static void xdg_surface_v6_set_window_geometry_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height
) {
    OwlZxdgSurfaceV6 *self = wl_resource_get_user_data(resource);
    NSRect rect = NSMakeRect(x, y, width, height);
    [self->_surface setPendingGeometry: rect];
}

static const struct zxdg_surface_v6_interface xdg_surface_v6_impl = {
    .destroy = xdg_surface_v6_destroy_handler,
    .get_toplevel = xdg_surface_v6_get_xdg_toplevel_handler,
    .get_popup = xdg_surface_v6_get_popup_handler,
    .set_window_geometry = xdg_surface_v6_set_window_geometry_handler,
    .ack_configure = xdg_surface_v6_ack_configure_handler
};

- (id) initWithResource: (struct wl_resource *) resource
                surface: (OwlSurface *) surface
{
    _resource = resource;
    _surface = [surface retain];
    wl_resource_set_implementation(
        resource,
        &xdg_surface_v6_impl,
        [self retain],
        xdg_surface_v6_destroy
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
    zxdg_surface_v6_send_configure(_resource, serial);
}

@end
