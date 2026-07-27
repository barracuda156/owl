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
#import "OwlXdgPositioner.h"
#import "xdg-shell.h"
#import <wayland-server.h>


/* A real, non-stub xdg_popup. Owl has no separate popup window
 * surface of its own (popups are drawn by the client into their own
 * wl_surface and owl has no on-screen placement for them beyond the
 * geometry math below), so grab is accepted but does not establish
 * an actual input grab; reposition recomputes geometry from the new
 * positioner and sends the full repositioned/configure/xdg_surface.configure
 * sequence the protocol requires. */
@interface OwlXdgPopup : NSObject {
@public
    struct wl_resource *_resource;
    OwlXdgSurface *_xdgSurface;
    OwlXdgSurface *_parentXdgSurface;
}

- (id) initWithResource: (struct wl_resource *) resource
              xdgSurface: (OwlXdgSurface *) xdgSurface
        parentXdgSurface: (OwlXdgSurface *) parentXdgSurface;

- (void) sendConfigureForPositioner: (OwlXdgPositioner *) positioner;

@end

@implementation OwlXdgPopup

- (void) sendConfigureForPositioner: (OwlXdgPositioner *) positioner {
    NSRect geometry = [positioner geometryRelativeToParent];

    // Wayland's y grows downward from the parent's window geometry
    // origin; our geometry math above works in the same convention
    // as -[OwlSurface windowGeometry], so no flip is needed here.
    xdg_popup_send_configure(
        _resource,
        (int32_t) geometry.origin.x,
        (int32_t) geometry.origin.y,
        (int32_t) geometry.size.width,
        (int32_t) geometry.size.height
    );
    [_xdgSurface sendConfigure];
}

static void xdg_popup_destroy_resource(struct wl_resource *resource) {
    OwlXdgPopup *self = wl_resource_get_user_data(resource);
    [self release];
}

static void xdg_popup_destroy_handler(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

static void xdg_popup_grab_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *seat_resource,
    uint32_t serial
) {
    // No explicit popup grab support; the request is accepted so
    // well-behaved clients (which always call this after get_popup)
    // don't see a protocol error, but no grab is actually taken.
}

static void xdg_popup_reposition_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *positioner_resource,
    uint32_t token
) {
    OwlXdgPopup *self = wl_resource_get_user_data(resource);
    OwlXdgPositioner *positioner = wl_resource_get_user_data(positioner_resource);

    xdg_popup_send_repositioned(resource, token);
    [self sendConfigureForPositioner: positioner];
}

static const struct xdg_popup_interface xdg_popup_impl = {
    .destroy = xdg_popup_destroy_handler,
    .grab = xdg_popup_grab_handler,
    .reposition = xdg_popup_reposition_handler
};

- (id) initWithResource: (struct wl_resource *) resource
              xdgSurface: (OwlXdgSurface *) xdgSurface
        parentXdgSurface: (OwlXdgSurface *) parentXdgSurface
{
    _resource = resource;
    _xdgSurface = [xdgSurface retain];
    _parentXdgSurface = [parentXdgSurface retain];
    wl_resource_set_implementation(
        resource,
        &xdg_popup_impl,
        [self retain],
        xdg_popup_destroy_resource
    );
    return self;
}

- (void) dealloc {
    [_xdgSurface release];
    [_parentXdgSurface release];
    [super dealloc];
}

@end


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
        wl_resource_get_version(resource),
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

static void xdg_surface_get_popup_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    struct wl_resource *parent_resource,
    struct wl_resource *positioner_resource
) {
    OwlXdgSurface *self = wl_resource_get_user_data(resource);
    OwlXdgSurface *parentXdgSurface = parent_resource != NULL
        ? wl_resource_get_user_data(parent_resource)
        : nil;
    OwlXdgPositioner *positioner = wl_resource_get_user_data(positioner_resource);

    struct wl_resource *popup_resource = wl_resource_create(
        client,
        &xdg_popup_interface,
        wl_resource_get_version(resource),
        id
    );
    OwlXdgPopup *popup = [OwlXdgPopup alloc];
    popup = [popup initWithResource: popup_resource
                          xdgSurface: self
                    parentXdgSurface: parentXdgSurface];
    [popup sendConfigureForPositioner: positioner];
    [popup release];
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
    .get_popup = xdg_surface_get_popup_handler,
    .set_window_geometry = xdg_surface_set_window_geometry_handler,
    .ack_configure = xdg_surface_ack_configure_handler
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

- (OwlSurface *) surface {
    return _surface;
}

@end
