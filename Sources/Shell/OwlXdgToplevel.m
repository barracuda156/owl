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

static NSMutableArray *toplevels;

+ (void) initialize {
    if (toplevels == nil) {
        toplevels = [[NSMutableArray alloc] initWithCapacity: 1];
    }
}

// Fired when a toplevel that some OTHER toplevel is set_parent'd to
// gets destroyed. data is the parent's resource, not useful for
// finding the child; recover it the same way
// OwlZwpRelativePointerManagerV1 recovers self for a listener on a
// foreign resource -- scan the live instances for whose
// _parentDestroyListener this is.
static void xdg_toplevel_parent_destroy_notify(
    struct wl_listener *listener,
    void *data
) {
    OwlXdgToplevel *self = nil;
    for (OwlXdgToplevel *toplevel in toplevels) {
        if (&toplevel->_parentDestroyListener == listener) {
            self = toplevel;
            break;
        }
    }
    if (self == nil) {
        return;
    }
    [self detachFromParent];
}

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
    // No -mouseExited: is coming for the window being closed; if
    // the cursor was inside, hand the pointer focus back cleanly.
    [OwlSurface relinquishPointerFocusOf: self->_surface];
    // Detach from our own parent, if any, before closing -- any
    // toplevels parented to US already detached themselves via
    // their own listener on this resource's destroy_signal, which
    // fires before this function runs.
    [self detachFromParent];
    [self->_window close];
    [toplevels removeObjectIdenticalTo: self];
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
    OwlXdgToplevel *self = wl_resource_get_user_data(resource);
    OwlXdgToplevel *parent = parent_resource != NULL
        ? wl_resource_get_user_data(parent_resource)
        : nil;

    if (parent == self) {
        wl_resource_post_error(
            resource,
            XDG_TOPLEVEL_ERROR_INVALID_PARENT,
            "xdg_toplevel cannot be parented to itself"
        );
        return;
    }
    if (self->_parent == parent) {
        return;
    }

    [self detachFromParent];
    self->_parent = parent;
    if (parent != nil) {
        self->_parentDestroyListener.notify = xdg_toplevel_parent_destroy_notify;
        wl_resource_add_destroy_listener(
            parent->_resource,
            &self->_parentDestroyListener
        );
        [self attachToParent];
    }
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
    OwlXdgToplevel *self = wl_resource_get_user_data(resource);
    self->_maxSize = NSMakeSize(width, height);
}

static void xdg_toplevel_set_min_size_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    int32_t width,
    int32_t height
) {
    OwlXdgToplevel *self = wl_resource_get_user_data(resource);
    self->_minSize = NSMakeSize(width, height);
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

    [toplevels addObject: self];

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

- (void) detachWindowFromParentWindow {
    NSWindow *window = [_window window];
    NSWindow *parentWindow = [window parentWindow];
    if (parentWindow != nil) {
        [parentWindow removeChildWindow: window];
    }
}

// Clears the logical parent relationship (ivar + listener on the
// parent's resource) and undoes the NSWindow-level attachment, if
// any. Called when set_parent picks a new parent, when the parent's
// resource is destroyed (via the notify function above), and when
// our own resource is destroyed.
- (void) detachFromParent {
    if (_parent == nil) {
        return;
    }
    wl_list_remove(&_parentDestroyListener.link);
    wl_list_init(&_parentDestroyListener.link);
    _parent = nil;
    [self detachWindowFromParentWindow];
}

// Applies the NSWindow-level addChildWindow for the current logical
// _parent, if both windows already exist. Called right after
// set_parent (when we're already mapped) and from -map (the common
// case: set_parent, then map). If the parent hasn't been mapped yet
// at either point, this is a silent no-op -- there is no hook to
// notify already-mapped children when a later-mapped parent's
// window appears, which is an accepted gap for how far this task
// goes (real transient dialogs map after their already-visible
// owner in practice).
- (void) attachToParent {
    if (_parent == nil) {
        return;
    }
    NSWindow *window = [_window window];
    NSWindow *parentWindow = [_parent->_window window];
    if (window == nil || parentWindow == nil) {
        return;
    }
    if ([window parentWindow] == parentWindow) {
        return;
    }
    // Refuse to create a child-window cycle (cloned from the popup
    // parenting guard in OwlXdgSurface.m): a hostile client could
    // otherwise chain toplevels into a loop, which AppKit does not
    // survive attaching.
    NSWindow *ancestor = parentWindow;
    while (ancestor != nil && ancestor != window) {
        ancestor = [ancestor parentWindow];
    }
    if (ancestor == nil) {
        [parentWindow addChildWindow: window ordered: NSWindowAbove];
    }
}

- (void) map {
    [self update];
    [_window map];
    [self attachToParent];
}

- (void) unmap {
    if (!_configured) {
        [self sendConfigureWithSize: NSZeroSize];
        return;
    }
    // Drop the NSWindow-level attachment while hidden, out of
    // caution around AppKit's behavior for attached-but-ordered-out
    // windows; the logical _parent ivar survives for -map to
    // re-apply it on the next map.
    [self detachWindowFromParentWindow];
    [_window unmap];
}

// Double-buffered per spec: set_min_size / set_max_size land in
// _minSize / _maxSize as they're requested, and -update (called on
// every commit of a mapped toplevel, and once at map) applies
// whatever's currently there. A negative component, or an effective
// min > max on an axis where both are set, is a protocol error; the
// values are left un-applied, which is fine because posting a
// protocol error is fatal to the client -- there's no next commit to
// worry about reverting for.
- (void) applyMinMaxSize {
    BOOL maxWidthSet = _maxSize.width > 0;
    BOOL maxHeightSet = _maxSize.height > 0;
    if (_minSize.width < 0 || _minSize.height < 0 ||
        _maxSize.width < 0 || _maxSize.height < 0 ||
        (maxWidthSet && _minSize.width > _maxSize.width) ||
        (maxHeightSet && _minSize.height > _maxSize.height)) {
        wl_resource_post_error(
            _resource,
            XDG_TOPLEVEL_ERROR_INVALID_SIZE,
            "invalid min/max size"
        );
        return;
    }

    NSSize minSize = NSMakeSize(
        (_minSize.width > 0) ? _minSize.width : 0.0,
        (_minSize.height > 0) ? _minSize.height : 0.0
    );
    NSSize maxSize = NSMakeSize(
        maxWidthSet ? _maxSize.width : CGFLOAT_MAX,
        maxHeightSet ? _maxSize.height : CGFLOAT_MAX
    );
    [_window setContentMinSize: minSize];
    [_window setContentMaxSize: maxSize];
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

    [self applyMinMaxSize];
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
