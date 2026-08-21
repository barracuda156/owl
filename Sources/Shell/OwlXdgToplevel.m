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

#import "OwlXdgToplevel.h"
#import "OwlSurface.h"
#import "OwlXdgSurface.h"
#import "OwlServer.h"
#import "OwlKeyboard.h"
#import "OwlWlDataDevice.h"
#import "OwlZwpPrimarySelectionDeviceV1.h"
#import "xdg-shell.h"
#import <wayland-server.h>


@implementation OwlXdgToplevel

static void xdg_toplevel_destroy(struct wl_resource *resource) {
    OwlXdgToplevel *self = wl_resource_get_user_data(resource);
    self->_destroying = YES;
    // The surface does not retain its role; detach ourselves so a
    // later commit cannot message a freed object. GTK in particular
    // destroys the xdg_toplevel on window close but keeps the
    // wl_surface around for the next map, and its very next commit
    // on that surface used to hit the dangling role and crash.
    if ([self->_surface role] == (id<OwlSurfaceRole>) self) {
        [self->_surface setRole: nil];
    }
    [self->_window close];
    [self release];
}

static void xdg_toplevel_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void xdg_toplevel_set_parent_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *parent_resource
) {
    // TODO
}

static void xdg_toplevel_set_title_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    const char *raw_title
) {
    OwlXdgToplevel *self = wl_resource_get_user_data(resource);
    [self->_window setTitle: [NSString stringWithUTF8String: raw_title]];
}

static void xdg_toplevel_set_app_id_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    const char *raw_app_id
) {
    // Do nothing.
}

static void xdg_toplevel_move_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *seat_resource,
    uint32_t serial
) {
    OwlXdgToplevel *self = wl_resource_get_user_data(resource);
    [[self->_window window] runInteractiveMove];
}

static void xdg_toplevel_resize_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *seat_resource,
    uint32_t serial,
    uint32_t edges
) {
    OwlXdgToplevel *self = wl_resource_get_user_data(resource);
    self->_resizing = YES;
    [self sendConfigureWithSize: NSZeroSize];
    [[self->_window window] runInteractiveResizeWithEdges: edges];
    self->_resizing = NO;
    [self sendConfigureWithSize: NSZeroSize];
}

static void xdg_toplevel_show_window_menu_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *seat_resource,
    uint32_t serial,
    int32_t x,
    int32_t y
) {
    // We don't have a window menu to show.
}

static void xdg_toplevel_set_fullscreen_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *output_resource
) {
    // We don't support fullscreen; re-send a configure without
    // the fullscreen state so the client knows it stayed
    // windowed.
    OwlXdgToplevel *self = wl_resource_get_user_data(resource);
    [self sendConfigureWithSize: NSZeroSize];
}

static void xdg_toplevel_unset_fullscreen_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    OwlXdgToplevel *self = wl_resource_get_user_data(resource);
    [self sendConfigureWithSize: NSZeroSize];
}

static void xdg_toplevel_set_max_size_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    int32_t width,
    int32_t height
) {
    // TODO
}

static void xdg_toplevel_set_min_size_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    int32_t width,
    int32_t height
) {
    // TODO
}

static void xdg_toplevel_set_minimized_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    OwlXdgToplevel *self = wl_resource_get_user_data(resource);
    [self->_window minimize];
}

static void xdg_toplevel_set_maximized_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    OwlXdgToplevel *self = wl_resource_get_user_data(resource);
    [self->_window maximize];
}

static void xdg_toplevel_unset_maximized_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    OwlXdgToplevel *self = wl_resource_get_user_data(resource);
    [self->_window unmaximize];
}

static const struct xdg_toplevel_interface xdg_toplevel_impl = {
    .destroy = xdg_toplevel_destroy_handler,
    .set_parent = xdg_toplevel_set_parent_handler,
    .set_title = xdg_toplevel_set_title_handler,
    .set_app_id = xdg_toplevel_set_app_id_handler,
    .show_window_menu = xdg_toplevel_show_window_menu_handler,
    .move = xdg_toplevel_move_handler,
    .resize = xdg_toplevel_resize_handler,
    .set_max_size = xdg_toplevel_set_max_size_handler,
    .set_min_size = xdg_toplevel_set_min_size_handler,
    .set_minimized = xdg_toplevel_set_minimized_handler,
    .set_maximized = xdg_toplevel_set_maximized_handler,
    .unset_maximized = xdg_toplevel_unset_maximized_handler,
    .set_fullscreen = xdg_toplevel_set_fullscreen_handler,
    .unset_fullscreen = xdg_toplevel_unset_fullscreen_handler
};

- (id) initWithResource: (struct wl_resource *) resource
                surface: (OwlSurface *) surface
             xdgSurface: (OwlXdgSurface *) xdgSurface
{
    _resource = resource;
    _surface = [surface retain];
    _xdgSurface = xdgSurface;

    [surface setRole: self];
    _window = [OwlWindowWrapper new];
    [_window setView: surface];
    [_window setWindowDelegate: self];

    wl_resource_set_implementation(
        resource,
        &xdg_toplevel_impl,
        [self retain],
        xdg_toplevel_destroy
    );

    if (wl_resource_get_version(resource) >= XDG_TOPLEVEL_WM_CAPABILITIES_SINCE_VERSION) {
        struct wl_array capabilities;
        wl_array_init(&capabilities);

#define append_capability(value)                                \
        do {                                                    \
            void *ptr = wl_array_add(                           \
                &capabilities,                                  \
                sizeof(enum xdg_toplevel_wm_capabilities)        \
            );                                                  \
            *(enum xdg_toplevel_wm_capabilities *) ptr = (value); \
        } while (0)

        // No WINDOW_MENU: owl has no window menu to show.
        append_capability(XDG_TOPLEVEL_WM_CAPABILITIES_MAXIMIZE);
        append_capability(XDG_TOPLEVEL_WM_CAPABILITIES_FULLSCREEN);
        append_capability(XDG_TOPLEVEL_WM_CAPABILITIES_MINIMIZE);

#undef append_capability

        xdg_toplevel_send_wm_capabilities(resource, &capabilities);
        wl_array_release(&capabilities);
    }

    return self;
}

- (void) dealloc {
    [_surface release];
    [_window release];
    [super dealloc];
}

- (struct wl_array) makeStates {
    struct wl_array states;
    wl_array_init(&states);

#define append(condition, value)                    \
    if (condition) {                                \
        void *ptr = wl_array_add(                   \
            &states,                                \
            sizeof(enum xdg_toplevel_state)         \
        );                                          \
        *(enum xdg_toplevel_state *) ptr = (value); \
    } else

    append(_activated, XDG_TOPLEVEL_STATE_ACTIVATED);
    append(_fullscreen, XDG_TOPLEVEL_STATE_FULLSCREEN);
    append(_resizing, XDG_TOPLEVEL_STATE_RESIZING);
    append(_maximized, XDG_TOPLEVEL_STATE_MAXIMIZED);
    if (wl_resource_get_version(_resource) >= XDG_TOPLEVEL_STATE_SUSPENDED_SINCE_VERSION) {
        append(_suspended, XDG_TOPLEVEL_STATE_SUSPENDED);
    }

#undef append

    return states;
}

- (void) sendConfigureWithSize: (NSSize) size {
    if (wl_resource_get_version(_resource) >= XDG_TOPLEVEL_CONFIGURE_BOUNDS_SINCE_VERSION) {
        NSSize bounds = [[NSScreen mainScreen] visibleFrame].size;
        xdg_toplevel_send_configure_bounds(_resource, bounds.width, bounds.height);
    }

    struct wl_array states = [self makeStates];
    xdg_toplevel_send_configure(
        _resource,
        size.width,
        size.height,
        &states
    );
    [_xdgSurface sendConfigure];
    wl_array_release(&states);
    _configured = YES;

    // Flush events to client immediately
    struct wl_client *client = wl_resource_get_client(_resource);
    wl_client_flush(client);
}

- (OwlWindowWrapper *) windowWrapper {
    return _window;
}

- (OwlKeyboard *) keyboard {
    struct wl_client *client = wl_resource_get_client(_resource);
    return [OwlKeyboard keyboardForClient: client];
}

- (OwlWlDataDevice *) dataDevice {
    struct wl_client *client = wl_resource_get_client(_resource);
    return [OwlWlDataDevice dataDeviceForClient: client];
}

- (OwlZwpPrimarySelectionDeviceV1 *) primaryDataDevice {
    struct wl_client *client = wl_resource_get_client(_resource);
    return [OwlZwpPrimarySelectionDeviceV1 deviceForClient: client];
}

- (uint32_t) serial {
    struct wl_client *client = wl_resource_get_client(_resource);
    struct wl_display *display = wl_client_get_display(client);
    return wl_display_next_serial(display);
}

- (void) map {
    [self update];
    [_window map];
}

- (void) unmap {
    if (!_configured) {
        [self sendConfigureWithSize: NSZeroSize];
        return;
    }
    [_window unmap];
}

- (void) update {
    // Size the window to the client's window geometry, not the
    // full buffer: CSD clients (GTK) draw drop shadows around the
    // actual window content and tell us via set_window_geometry
    // which part is the window. Offset the surface view inside the
    // content view so the geometry rect lands exactly in it; the
    // shadow margins around it are clipped away.
    NSRect geometry = [_surface windowGeometry];
    [_window setContentSize: geometry.size];

    NSPoint origin;
    origin.x = -geometry.origin.x;
    // geometry.origin.y is measured from the surface's top edge
    // downward; Cocoa view origins are bottom-left.
    origin.y = geometry.origin.y + geometry.size.height
        - [_surface frame].size.height;
    if (!NSEqualPoints([_surface frame].origin, origin)) {
        [_surface setFrameOrigin: origin];
        [_surface updateTrackingRect];
    }
}

- (void) windowDidResize: (NSNotification *) notification {
    if (_destroying) return;
    NSWindow *w = [notification object];
    _maximized = NO; // [w isZoomed];
    NSRect frame = [w frame];
    // The content area shows exactly the window geometry, and the
    // size in a configure event is in window-geometry coordinates,
    // so the content size can be sent as is.
    NSSize s = [w contentRectForFrameRect: frame].size;
    [self sendConfigureWithSize: s];
}

- (BOOL) windowShouldClose: (NSWindow *) w {
    if (_destroying) return YES;
    xdg_toplevel_send_close(_resource);
    [[OwlServer sharedServer] flushClientsLater];
    return NO;
}

- (void) windowWillClose: (NSNotification *) notification {
    // Unsubscribe so we don't get didResignMain.
    [_window setWindowDelegate: nil];
}

- (void) windowDidBecomeMain: (NSNotification *) notification {
    if (_destroying) return;
    _activated = YES;
    [self sendConfigureWithSize: NSZeroSize];
}

- (void) windowDidResignMain: (NSNotification *) notification {
    if (_destroying) return;
    _activated = NO;
    [self sendConfigureWithSize: NSZeroSize];
}

- (void) windowDidMiniaturize: (NSNotification *) notification {
    if (_destroying) return;
    _suspended = YES;
    [self sendConfigureWithSize: NSZeroSize];
}

- (void) windowDidDeminiaturize: (NSNotification *) notification {
    if (_destroying) return;
    _suspended = NO;
    [self sendConfigureWithSize: NSZeroSize];
}

- (void) windowDidBecomeKey: (NSNotification *) notification {
    if (_destroying) return;
    [[self keyboard] sendEnterSurface: _surface];
    [[self dataDevice] focused];
    [[self primaryDataDevice] focused];
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) windowDidResignKey: (NSNotification *) notification {
    if (_destroying) return;
    [[self keyboard] sendLeaveSurface: _surface];
    [[self dataDevice] unfocused];
    [[self primaryDataDevice] unfocused];
    [[OwlServer sharedServer] flushClientsLater];
}

@end
