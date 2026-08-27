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

#import "OwlXdgWmBase.h"
#import "OwlSurface.h"
#import "OwlXdgSurface.h"
#import "OwlXdgPositioner.h"
#import "xdg-shell.h"
#import <wayland-server.h>

@implementation OwlXdgWmBase

static void xdg_wm_base_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void xdg_wm_base_destroy(
    struct wl_resource *resource
) {
    OwlXdgWmBase *self = wl_resource_get_user_data(resource);
    [self release];
}

static void xdg_positioner_destroy_resource(struct wl_resource *resource) {
    OwlXdgPositioner *self = wl_resource_get_user_data(resource);
    [self release];
}

static void xdg_positioner_destroy(struct wl_client *client, struct wl_resource *resource) {
    wl_resource_destroy(resource);
}

static void xdg_positioner_set_size(struct wl_client *client, struct wl_resource *resource,
    int32_t width, int32_t height)
{
    OwlXdgPositioner *self = wl_resource_get_user_data(resource);
    self->_size = NSMakeSize(width, height);
}

static void xdg_positioner_set_anchor_rect(struct wl_client *client, struct wl_resource *resource,
    int32_t x, int32_t y, int32_t width, int32_t height)
{
    OwlXdgPositioner *self = wl_resource_get_user_data(resource);
    self->_anchorRect = NSMakeRect(x, y, width, height);
}

static void xdg_positioner_set_anchor(struct wl_client *client, struct wl_resource *resource,
    uint32_t anchor)
{
    OwlXdgPositioner *self = wl_resource_get_user_data(resource);
    self->_anchor = anchor;
}

static void xdg_positioner_set_gravity(struct wl_client *client, struct wl_resource *resource,
    uint32_t gravity)
{
    OwlXdgPositioner *self = wl_resource_get_user_data(resource);
    self->_gravity = gravity;
}

static void xdg_positioner_set_constraint_adjustment(struct wl_client *client, struct wl_resource *resource,
    uint32_t constraint_adjustment)
{
    OwlXdgPositioner *self = wl_resource_get_user_data(resource);
    self->_constraintAdjustment = constraint_adjustment;
}

static void xdg_positioner_set_offset(struct wl_client *client, struct wl_resource *resource,
    int32_t x, int32_t y)
{
    OwlXdgPositioner *self = wl_resource_get_user_data(resource);
    self->_offset = NSMakePoint(x, y);
}

static void xdg_positioner_set_reactive(struct wl_client *client, struct wl_resource *resource) {
    // constraint_adjustment is applied once, at the initial
    // xdg_popup.configure (see -[OwlXdgPopup
    // sendConfigureForPositioner:]); reconstraining a mapped popup
    // in response to the parent moving/resizing (what set_reactive
    // asks for) is out of scope -- accept and ignore.
}

static void xdg_positioner_set_parent_size(struct wl_client *client, struct wl_resource *resource,
    int32_t parent_width, int32_t parent_height) { /* unused: only informs reactive repositioning, which we don't do */ }

static void xdg_positioner_set_parent_configure(struct wl_client *client, struct wl_resource *resource,
    uint32_t serial) { /* unused: only informs reactive repositioning, which we don't do */ }

static const struct xdg_positioner_interface xdg_positioner_impl = {
    .destroy = xdg_positioner_destroy,
    .set_size = xdg_positioner_set_size,
    .set_anchor_rect = xdg_positioner_set_anchor_rect,
    .set_anchor = xdg_positioner_set_anchor,
    .set_gravity = xdg_positioner_set_gravity,
    .set_constraint_adjustment = xdg_positioner_set_constraint_adjustment,
    .set_offset = xdg_positioner_set_offset,
    .set_reactive = xdg_positioner_set_reactive,
    .set_parent_size = xdg_positioner_set_parent_size,
    .set_parent_configure = xdg_positioner_set_parent_configure
};

static void xdg_wm_base_create_positioner(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id
) {
    struct wl_resource *positioner_resource = wl_resource_create(
        client,
        &xdg_positioner_interface,
        wl_resource_get_version(resource),
        id
    );
    OwlXdgPositioner *positioner = [OwlXdgPositioner new];
    wl_resource_set_implementation(
        positioner_resource,
        &xdg_positioner_impl,
        positioner,
        xdg_positioner_destroy_resource
    );
}

static void xdg_wm_base_get_xdg_surface(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    struct wl_resource *surface_resource
) {
    struct wl_resource *xdg_surface_resource = wl_resource_create(
        client,
        &xdg_surface_interface,
        wl_resource_get_version(resource),
        id
    );

    OwlSurface *surface = wl_resource_get_user_data(surface_resource);
    [[[OwlXdgSurface alloc] initWithResource: xdg_surface_resource
                                     surface: surface] release];
}

static void xdg_wm_base_pong(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t serial
) {
    /* Client responded to ping - nothing to do */
}

static const struct xdg_wm_base_interface xdg_wm_base_impl = {
    .destroy = xdg_wm_base_destroy_handler,
    .create_positioner = xdg_wm_base_create_positioner,
    .get_xdg_surface = xdg_wm_base_get_xdg_surface,
    .pong = xdg_wm_base_pong
};

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &xdg_wm_base_impl,
        [self retain],
        NULL
    );
    return self;
}

static void xdg_wm_base_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &xdg_wm_base_interface,
        version,
        id
    );
    [[[OwlXdgWmBase alloc] initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    wl_global_create(
        display,
        &xdg_wm_base_interface,
        6,
        NULL,
        xdg_wm_base_bind
    );
}

@end
