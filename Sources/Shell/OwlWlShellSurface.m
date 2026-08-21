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

#import "OwlWlShellSurface.h"
#import "OwlSurface.h"
#import "OwlWindowWrapper.h"
#import <wayland-server.h>

@implementation OwlWlShellSurface

static void shell_surface_destroy(struct wl_resource *resource) {
    OwlWlShellSurface *self = wl_resource_get_user_data(resource);
    // The surface does not retain its role; detach ourselves so a
    // later commit cannot message a freed object (see the stable
    // xdg_toplevel destructor).
    if ([self->_surface role] == (id<OwlSurfaceRole>) self) {
        [self->_surface setRole: nil];
    }
    // No -mouseExited: is coming for the window being closed; if
    // the cursor was inside, hand the pointer focus back cleanly.
    [OwlSurface relinquishPointerFocusOf: self->_surface];
    [self->_window close];
    [self release];
}

static void shell_surface_pong_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t serial
) {
    /* Client responded to ping - nothing to do */
}

static void shell_surface_move_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *seat_resource,
    uint32_t serial
) {
    OwlWlShellSurface *self = wl_resource_get_user_data(resource);
    [[self->_window window] runInteractiveMove];
}

static void shell_surface_resize_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *seat_resource,
    uint32_t serial,
    uint32_t edges
) {
    OwlWlShellSurface *self = wl_resource_get_user_data(resource);
    [[self->_window window] runInteractiveResizeWithEdges: edges];
}

static void shell_surface_set_toplevel_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    OwlWlShellSurface *self = wl_resource_get_user_data(resource);
    self->_mode = OWL_WL_SHELL_SURFACE_MODE_TOPLEVEL;
}

static void shell_surface_set_transient_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *parent_resource,
    int32_t x,
    int32_t y,
    uint32_t flags
) {
    // We don't support positioning transient surfaces relative to
    // their parent; treat it like a regular toplevel.
    OwlWlShellSurface *self = wl_resource_get_user_data(resource);
    self->_mode = OWL_WL_SHELL_SURFACE_MODE_TOPLEVEL;
}

static void shell_surface_set_fullscreen_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t method,
    uint32_t framerate,
    struct wl_resource *output_resource
) {
    // We don't support fullscreen.
}

static void shell_surface_set_popup_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *seat_resource,
    uint32_t serial,
    struct wl_resource *parent_resource,
    int32_t x,
    int32_t y,
    uint32_t flags
) {
    // We don't support popups on wl_shell; treat it like a regular
    // toplevel.
    OwlWlShellSurface *self = wl_resource_get_user_data(resource);
    self->_mode = OWL_WL_SHELL_SURFACE_MODE_TOPLEVEL;
}

static void shell_surface_set_maximized_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *output_resource
) {
    OwlWlShellSurface *self = wl_resource_get_user_data(resource);
    [self->_window maximize];
}

static void shell_surface_set_title_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    const char *raw_title
) {
    OwlWlShellSurface *self = wl_resource_get_user_data(resource);
    [self->_window setTitle: [NSString stringWithUTF8String: raw_title]];
}

static void shell_surface_set_class_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    const char *class_
) {
    // Do nothing.
}

static const struct wl_shell_surface_interface shell_surface_interface = {
    .pong = shell_surface_pong_handler,
    .move = shell_surface_move_handler,
    .resize = shell_surface_resize_handler,
    .set_toplevel = shell_surface_set_toplevel_handler,
    .set_transient = shell_surface_set_transient_handler,
    .set_fullscreen = shell_surface_set_fullscreen_handler,
    .set_popup = shell_surface_set_popup_handler,
    .set_maximized = shell_surface_set_maximized_handler,
    .set_title = shell_surface_set_title_handler,
    .set_class = shell_surface_set_class_handler
};

- (id) initWithResource: (struct wl_resource *) resource
                surface: (OwlSurface *) surface
{
    _resource = resource;
    _surface = [surface retain];

    [surface setRole: self];
    _window = [OwlWindowWrapper new];
    [_window setView: surface];

    wl_resource_set_implementation(
        resource,
        &shell_surface_interface,
        [self retain],
        shell_surface_destroy
    );
    return self;
}

- (void) dealloc {
    [_surface release];
    [_window release];
    [super dealloc];
}

- (void) map {
    [self update];
    [_window map];
}

- (void) unmap {
    [_window unmap];
}

- (void) update {
    [_window setContentSize: [_surface bounds].size];
}

@end
