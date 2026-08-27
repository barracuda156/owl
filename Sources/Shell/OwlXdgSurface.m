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
#import "OwlPopupWindow.h"
#import "OwlServer.h"
#import "OwlKeyboard.h"
#import "OwlWlDataDevice.h"
#import "OwlZwpPrimarySelectionDeviceV1.h"
#import "xdg-shell.h"
#import <wayland-server.h>


/* A real xdg_popup. The popup surface is hosted in a borderless
 * OwlPopupWindow, attached to the parent surface's window as a
 * child window and placed at the position computed from the
 * xdg_positioner. The grab request is accepted but not enforced
 * compositor-side beyond making the popup window key, which moves
 * the keyboard focus to the popup the way a grab is supposed to;
 * clients like GTK also keep their own client-side grab, which
 * dismisses the popup when a click lands elsewhere in the
 * application. reposition recomputes geometry from the new
 * positioner and sends the full repositioned/configure/
 * xdg_surface.configure sequence the protocol requires. */
@interface OwlXdgPopup : NSObject <OwlSurfaceRole, NSWindowDelegate> {
@public
    struct wl_resource *_resource;
    OwlXdgSurface *_xdgSurface;
    OwlXdgSurface *_parentXdgSurface;
    OwlPopupWindow *_window;
    // The position last sent in xdg_popup.configure, relative to
    // the parent's window geometry origin, y growing downward.
    NSPoint _position;
    // Whether the client called xdg_popup.grab (always before the
    // popup maps). Only a grabbing popup (a menu) takes the key
    // status; a grabless one (a tooltip) must not steal the
    // keyboard focus from the window under it.
    BOOL _wantsGrab;
    BOOL _destroying;
}

- (id) initWithResource: (struct wl_resource *) resource
              xdgSurface: (OwlXdgSurface *) xdgSurface
        parentXdgSurface: (OwlXdgSurface *) parentXdgSurface;

- (void) sendConfigureForPositioner: (OwlXdgPositioner *) positioner;

// The screen point O corresponding to the parent's window-geometry
// origin (its Wayland (0,0), a top-left in Cocoa y-up terms), and
// the parent window's NSScreen. Returns NO (leaving both out
// params untouched) if the parent has no window yet, in which case
// callers should skip constraint adjustment / on-screen placement
// entirely, same as before this existed.
- (BOOL) parentOrigin: (NSPoint *) outOrigin screen: (NSScreen **) outScreen;

@end

@implementation OwlXdgPopup

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

- (BOOL) parentOrigin: (NSPoint *) outOrigin screen: (NSScreen **) outScreen {
    OwlSurface *parentSurface = [_parentXdgSurface surface];
    NSWindow *parentWindow = [parentSurface window];
    if (parentWindow == nil) {
        return NO;
    }
    NSRect parentGeometry = [parentSurface windowGeometry];
    NSPoint inParentView = NSMakePoint(
        parentGeometry.origin.x,
        [parentSurface bounds].size.height - parentGeometry.origin.y
    );
    NSPoint inWindow = [parentSurface convertPoint: inParentView
                                             toView: nil];
    *outOrigin = [parentWindow convertBaseToScreen: inWindow];
    if (outScreen != NULL) {
        *outScreen = [parentWindow screen];
    }
    return YES;
}

- (void) sendConfigureForPositioner: (OwlXdgPositioner *) positioner {
    NSRect geometry;
    NSPoint origin;
    NSScreen *screen;
    if ([self parentOrigin: &origin screen: &screen] && screen != nil) {
        // Bring the screen's visible area (excludes the menu bar
        // and Dock -- deliberate, so a menu doesn't slide under
        // them) into the same parent-window-geometry-relative,
        // y-down space -[OwlXdgPositioner geometryRelativeToParent]
        // works in. Worked example: screen 1440x900 at (0,0), 25px
        // menu bar (visibleFrame (0,0,1440,875)), origin (100,800)
        // -> box x in [-100,1340], y in [-75,800]. A popup at
        // (10,780,200x100) has bottom edge 880 > 800: constrained
        // on y by 80; FLIP_Y with anchor/gravity BOTTOM->TOP puts
        // it above the anchor; if that still doesn't fit, SLIDE
        // moves it up 80 to y = 700.
        NSRect visibleFrame = [screen visibleFrame];
        NSRect box = NSMakeRect(
            NSMinX(visibleFrame) - origin.x,
            origin.y - NSMaxY(visibleFrame),
            NSWidth(visibleFrame),
            NSHeight(visibleFrame)
        );
        geometry = [positioner geometryRelativeToParentConstrainedTo: box];
    } else {
        // No parent window (or, on GNUstep, no NSScreen) to
        // constrain against yet; send the unadjusted position, as
        // owl always did before this existed.
        geometry = [positioner geometryRelativeToParent];
    }
    _position = geometry.origin;

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

// Compute and apply the popup's size and on-screen position from
// the configured position and the current window geometries.
- (void) updatePlacement {
    OwlSurface *surface = [_xdgSurface surface];
    NSRect geometry = [surface windowGeometry];

    // This runs on every commit of the popup surface, which for a
    // hovered GTK menu means pointer-motion rate; only touch the
    // window when something actually changed, or the WindowServer
    // gets a resize/move transaction (with a shadow recompute for
    // this transparent window) per repaint.
    if (!NSEqualSizes([_window frame].size, geometry.size)) {
        // Borderless window: the frame is the content area.
        [_window setContentSize: geometry.size];
    }

    // Clip the popup's window-geometry margins (CSD menu shadows)
    // the same way toplevel windows do.
    NSPoint viewOrigin;
    viewOrigin.x = -geometry.origin.x;
    viewOrigin.y = geometry.origin.y + geometry.size.height
        - [surface frame].size.height;
    if (!NSEqualPoints([surface frame].origin, viewOrigin)) {
        [surface setFrameOrigin: viewOrigin];
        [surface updateTrackingRect];
    }

    // The configured position is relative to the parent's window
    // geometry origin O, y growing downward; onScreen = O + (x, -y)
    // since screen coordinates grow upward (see -parentOrigin:
    // screen: for how O is derived, which folds in any offset the
    // parent's own view has -- both its geometry clipping and the
    // parent being a popup in its own right).
    NSPoint origin;
    if (![self parentOrigin: &origin screen: NULL]) {
        return;
    }
    NSPoint onScreen = NSMakePoint(
        origin.x + _position.x,
        origin.y - _position.y
    );
    // Read the frame after the possible resize above; the top-left
    // point depends on the height.
    NSRect frame = [_window frame];
    NSPoint currentTopLeft = NSMakePoint(
        frame.origin.x,
        frame.origin.y + frame.size.height
    );
    if (!NSEqualPoints(currentTopLeft, onScreen)) {
        [_window setFrameTopLeftPoint: onScreen];
    }
}

- (void) map {
    OwlSurface *surface = [_xdgSurface surface];
    if (_window == nil) {
        _window = [[OwlPopupWindow alloc]
            initWithContentRect: NSMakeRect(0, 0, 1, 1)];
        [[_window contentView] addSubview: surface];
        [_window setDelegate: self];
    }
    [self updatePlacement];

    NSWindow *parentWindow = [[_parentXdgSurface surface] window];
    if (parentWindow != nil && [_window parentWindow] == nil) {
        // Refuse to create a child-window cycle: a buggy or
        // hostile client can chain popups into a loop (popup A
        // parented on popup B and vice versa), and AppKit would
        // not survive the attachment.
        NSWindow *ancestor = parentWindow;
        while (ancestor != nil && ancestor != _window) {
            ancestor = [ancestor parentWindow];
        }
        if (ancestor == nil) {
            [parentWindow addChildWindow: _window ordered: NSWindowAbove];
        }
    }
    [_window makeFirstResponder: surface];
    if (_wantsGrab) {
        [_window makeKeyAndOrderFront: nil];
    } else {
        [_window orderFront: nil];
    }
}

- (void) unmap {
    if (_window == nil) {
        return;
    }
    // If the cursor is inside the popup, its view will get no
    // -mouseExited: for the window going away; hand the pointer
    // focus back explicitly, or the client is left with a focus
    // pointing at a gone surface and drops all further motion.
    [OwlSurface relinquishPointerFocusOf: [_xdgSurface surface]];
    NSWindow *parentWindow = [_window parentWindow];
    BOOL wasKey = [_window isKeyWindow];
    [parentWindow removeChildWindow: _window];
    [_window orderOut: nil];
    // Hand the key status back to the parent, so the toplevel
    // regains the keyboard focus when a menu closes.
    if (wasKey && parentWindow != nil) {
        [parentWindow makeKeyWindow];
    }
}

- (void) update {
    [self updatePlacement];
}

- (void) windowDidBecomeKey: (NSNotification *) notification {
    if (_destroying) return;
    [[self keyboard] sendEnterSurface: [_xdgSurface surface]];
    [[self dataDevice] focused];
    [[self primaryDataDevice] focused];
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) windowDidResignKey: (NSNotification *) notification {
    if (_destroying) return;
    [[self keyboard] sendLeaveSurface: [_xdgSurface surface]];
    [[self dataDevice] unfocused];
    [[self primaryDataDevice] unfocused];
    [[OwlServer sharedServer] flushClientsLater];
    if (_wantsGrab) {
        // The new key window is not knowable yet (Cocoa resigns
        // the old key window before appointing the new one), so
        // check whether the grab actually broke on the next run
        // loop pass.
        [self performSelector: @selector(checkGrabBroken)
                   withObject: nil
                   afterDelay: 0.0];
    }
}

// A grabbing popup whose key status went anywhere other than one
// of its own descendant popups has lost the grab; the protocol
// wants popup_done then, so that e.g. a click landing on another
// application still dismisses the menu.
- (void) checkGrabBroken {
    if (_destroying || _window == nil || ![_window isVisible]) {
        return;
    }
    NSWindow *w = [NSApp keyWindow];
    while (w != nil && w != _window) {
        w = [w parentWindow];
    }
    if (w == _window) {
        // The key status is on ourselves or on a descendant
        // popup (a submenu); the grab holds.
        return;
    }
    xdg_popup_send_popup_done(_resource);
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) teardown {
    [NSObject cancelPreviousPerformRequestsWithTarget: self];
    OwlSurface *surface = [_xdgSurface surface];
    if ([surface role] == (id<OwlSurfaceRole>) self) {
        [surface setRole: nil];
    }
    if (_window == nil) {
        return;
    }
    // The delegate is detached below, so windowDidResignKey won't
    // run for the orderOut; send the keyboard leave ourselves
    // before the parent takes the key status back.
    if ([_window isKeyWindow]) {
        [[self keyboard] sendLeaveSurface: surface];
        [[self dataDevice] unfocused];
        [[self primaryDataDevice] unfocused];
        [[OwlServer sharedServer] flushClientsLater];
    }
    [_window setDelegate: nil];
    [self unmap];
    [surface removeFromSuperview];
    [_window close];
    [_window release];
    _window = nil;
}

static void xdg_popup_destroy_resource(struct wl_resource *resource) {
    OwlXdgPopup *self = wl_resource_get_user_data(resource);
    self->_destroying = YES;
    [self teardown];
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
    // No compositor-side input grab is taken; the popup window
    // becoming key on map already gives the popup the keyboard
    // focus, and the client's own grab logic handles dismissal.
    // The protocol requires grab to be issued before the popup is
    // mapped, so recording the wish here is early enough.
    OwlXdgPopup *self = wl_resource_get_user_data(resource);
    self->_wantsGrab = YES;
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
    if (self->_window != nil) {
        [self updatePlacement];
    }
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
    // NULL rather than nil: the "id" parameter shadows the type.
    if ([self->_surface role] != NULL) {
        wl_resource_post_error(
            resource,
            XDG_SURFACE_ERROR_ALREADY_CONSTRUCTED,
            "the surface already has a role"
        );
        return;
    }
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
    // NULL rather than nil: GCC's ObjC headers define nil as (id)0,
    // which fails to parse here where the id type is shadowed by the
    // "id" parameter of this handler.
    OwlXdgSurface *parentXdgSurface = parent_resource != NULL
        ? wl_resource_get_user_data(parent_resource)
        : NULL;
    OwlXdgPositioner *positioner = wl_resource_get_user_data(positioner_resource);

    if ([self->_surface role] != NULL) {
        wl_resource_post_error(
            resource,
            XDG_SURFACE_ERROR_ALREADY_CONSTRUCTED,
            "the surface already has a role"
        );
        return;
    }
    if (parentXdgSurface == self) {
        wl_resource_post_error(
            resource,
            XDG_WM_BASE_ERROR_INVALID_POPUP_PARENT,
            "a popup cannot be its own parent"
        );
        return;
    }

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
    [self->_surface setRole: popup];
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

- (OwlSurface *) surface {
    return _surface;
}

@end
