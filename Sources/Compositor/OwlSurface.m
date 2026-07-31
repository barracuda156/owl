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

#import "OwlSurface.h"
#import "OwlCallback.h"
#import "OwlWpPresentation.h"
#import "OwlPointer.h"
#import "OwlKeyboard.h"
#import "OwlServer.h"
#import "OwlBuffer.h"
#import "OwlSurfaceState.h"
#import <wayland-server.h>
#import <Cocoa/Cocoa.h>


@implementation OwlSurface

- (struct wl_resource *) resource {
    return _resource;
}

static void surface_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void surface_destroy(struct wl_resource *resource) {
    OwlSurface *self = wl_resource_get_user_data(resource);
    // Neither the queued presentation feedbacks nor those still in
    // the pending state can ever be presented now; let the client
    // know. (On an abrupt disconnect the feedback resources may be
    // destroyed already, which makes these no-ops.)
    [self discardPresentationFeedbacks];
    for (OwlWpPresentationFeedback *feedback
             in [self->_pendingState presentationFeedbacks]) {
        [feedback sendDiscarded];
    }
    [self removeFromSuperview];
    [self release];
}

- (void) attachBuffer: (OwlBuffer *) buffer {
    [_pendingState setBuffer: buffer];
    [buffer invalidate];
}

static void surface_attach_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *buffer_resource,
    int32_t x,
    int32_t y
) {
    OwlSurface *self = wl_resource_get_user_data(resource);
    OwlBuffer *buffer = [OwlBuffer bufferForResource: buffer_resource];
    [self attachBuffer: buffer];
}

static void surface_damage_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height
) {
    OwlSurface *self = wl_resource_get_user_data(resource);
    NSRect rect = NSMakeRect(x, y, width, height);
    [self->_pendingState addDamage: rect];
}

static void surface_damage_buffer_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height
) {
    // We don't support buffer scales or transforms, so buffer
    // coordinates are the same as surface coordinates.
    surface_damage_handler(client, resource, x, y, width, height);
}

- (void) setPendingGeometry: (NSRect) geometry {
    [_pendingState setGeometry: geometry];
}

- (NSRect) windowGeometry {
    NSRect geometry = [_currentState geometry];
    if (geometry.size.width == 0) {
        return [self bounds];
    }
    return geometry;
}

- (NSSize) geometrySizeAdjustements {
    NSSize currentSize = [_currentState geometry].size;
    if (currentSize.width == 0) {
        return NSZeroSize;
    }

    NSSize res;

    res.width = [self frame].size.width - currentSize.width;
    res.height = [self frame].size.height - currentSize.height;

    return res;
}

- (void) setUpGL {
    NSOpenGLPixelFormatAttribute attrs[] = { 0 };
    NSOpenGLPixelFormat *format = [NSOpenGLPixelFormat alloc];
    format = [format initWithAttributes: attrs];
    _openGLContext = [[NSOpenGLContext alloc] initWithFormat: format
                                                shareContext: nil];
    [format release];
}

- (void) tearDownGL {
    // Called unconditionally from -dealloc, including for surfaces
    // that never had a GL context (shm-only clients like foot). Only
    // touch global GL state if we actually own it: on Mac OS X 10.6
    // ppc, CGLSetCurrentContext(NULL) crashes (a store to
    // NULL+0xbdc) when invoked with no context current, taking the
    // whole compositor down when a client disconnects.
    if (_openGLContext == nil) {
        return;
    }
    if ([NSOpenGLContext currentContext] == _openGLContext) {
        [NSOpenGLContext clearCurrentContext];
    }
    [_openGLContext clearDrawable];
    [_openGLContext release];
    _openGLContext = nil;
}

- (void) updateTrackingRect {
    if (_trackingRectTag != 0) {
        [self removeTrackingRect: _trackingRectTag];
    }
    _trackingRectTag = [self addTrackingRect: [self bounds]
                                       owner: self
                                    userData: NULL
                                assumeInside: NO];
}

- (void) commit {
    OwlBuffer *oldBuffer = [_currentState buffer];
    OwlBuffer *newBuffer = [_pendingState buffer];
    BOOL oldBufferNeedsGL = [oldBuffer needsGLForRendering];
    BOOL newBufferNeedsGL = [newBuffer needsGLForRendering];

    // We're going to "map" the surface if it wasn't
    // mapped previously and the new buffer is not nil.
    BOOL map = oldBuffer == nil && newBuffer != nil;
    // Conversely, we're going to unmap it if the new
    // buffer is actually nil. We're going to call
    // [role unmap] even if wasn't mapped; the roles
    // are expected to deal with it by e.g. sending
    // some sort of a configure event.
    BOOL unmap = newBuffer == nil;

    BOOL setUpGL = !oldBufferNeedsGL && newBufferNeedsGL;
    BOOL tearDownGL = oldBufferNeedsGL && !newBufferNeedsGL;
    BOOL damageAll = oldBufferNeedsGL != newBufferNeedsGL;

    if (setUpGL) {
        [self setUpGL];
    }

    if (oldBuffer != newBuffer) {
        [oldBuffer notifyDetached];
    }

    // Actually set the pending state as our new state.
    [_currentState release];
    _currentState = _pendingState;
    _pendingState = [OwlSurfaceState alloc];
    _pendingState = [_pendingState initWithPreviousState: _currentState];

    [_callbacks addObjectsFromArray: [_currentState callbacks]];

    // Any presentation feedbacks still queued at this point belong
    // to an earlier commit whose content never made it to the
    // screen; this commit supersedes it, so they are discarded.
    // Then queue the feedbacks of this new commit.
    [self discardPresentationFeedbacks];
    [_presentationFeedbacks addObjectsFromArray:
                                [_currentState presentationFeedbacks]];

    if (tearDownGL) {
        [self tearDownGL];
    }

    if (unmap) {
        [_role unmap];
        // We have no buffer, so -drawRect: is not going to run;
        // fire any pending frame callbacks so the client doesn't
        // wait for them forever, and discard the presentation
        // feedbacks - this content update will never be shown.
        [self fireCallbacks];
        [self discardPresentationFeedbacks];
        return;
    }

    BOOL willRedraw = NO;

    if (!NSEqualSizes([self frame].size, [newBuffer size])) {
        [self setFrameSize: [newBuffer size]];
        [self updateTrackingRect];
        [self setNeedsDisplay: YES];
        willRedraw = YES;
    }

    if (map) {
        [_role map];
        willRedraw = YES;
    } else {
        [_role update];
    }

    // Now, tell Cocoa to redraw this view.
    if (damageAll) {
        [self setNeedsDisplay: YES];
        willRedraw = YES;
    } else {
        for (NSValue *value in [_currentState damage]) {
            NSRect rect = [value rectValue];
            rect.origin.y = [newBuffer size].height - rect.size.height - rect.origin.y;
            [self setNeedsDisplayInRect: rect];
            willRedraw = YES;
        }
    }

    // If the client requested frame callbacks but this commit
    // won't cause a redraw (e.g. a commit with no damage), the
    // callbacks would never fire from -drawRect:, deadlocking
    // clients that wait for them before rendering. Fire them
    // right away instead. The committed content is identical to
    // what is already on the screen, so count the presentation
    // feedbacks as presented right away too.
    if (!willRedraw) {
        [self fireCallbacks];
        [self firePresentationFeedbacksPresented];
    }
}

- (void) fireCallbacks {
    if ([_callbacks count] == 0) {
        return;
    }
    uint32_t timestamp = [OwlServer timestamp];
    for (OwlCallback *callback in _callbacks) {
        [callback sendDoneWithData: timestamp];
    }
    [_callbacks removeAllObjects];
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) firePresentationFeedbacksPresented {
    if ([_presentationFeedbacks count] == 0) {
        return;
    }
    for (OwlWpPresentationFeedback *feedback in _presentationFeedbacks) {
        [feedback sendPresented];
    }
    [_presentationFeedbacks removeAllObjects];
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) discardPresentationFeedbacks {
    if ([_presentationFeedbacks count] == 0) {
        return;
    }
    for (OwlWpPresentationFeedback *feedback in _presentationFeedbacks) {
        [feedback sendDiscarded];
    }
    [_presentationFeedbacks removeAllObjects];
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) addPresentationFeedback: (OwlWpPresentationFeedback *) feedback {
    [_pendingState addPresentationFeedback: feedback];
}

static void surface_commit_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    OwlSurface *self = wl_resource_get_user_data(resource);
    [self commit];

    /* Notify pointer in case this is a cursor surface */
    [OwlPointer notifyCursorSurfaceCommit: resource];
}

- (void) drawRect: (NSRect) dirtyRect {
    // Ensure the GL context is set up correctly.
    // This has no effect if we're not using GL.
    [_openGLContext setView: self];
    [_openGLContext makeCurrentContext];

    [[_currentState buffer] drawInRect: [self bounds]];

    // We have painted; so send out all callbacks
    // and presentation feedbacks.
    [self fireCallbacks];
    [self firePresentationFeedbacksPresented];

    [[self window] invalidateShadow];
}

static void surface_set_opaque_region_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *region_resource
) {
    // TODO
}

static void surface_set_input_region_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *region_resource
) {
    // TODO
}

static void surface_set_buffer_scale_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    int32_t scale
) {
    // TODO
}

static void surface_set_buffer_transform_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    /* enum wl_output_transform */ int32_t transform
) {
    // TODO
}

static void surface_frame_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id
) {
    OwlSurface *self = wl_resource_get_user_data(resource);
    struct wl_resource *callback_resource = wl_resource_create(
        client,
        &wl_callback_interface,
        1,
        id
    );
    OwlCallback *callback = [[OwlCallback alloc] initWithResource: callback_resource];
    [self->_pendingState addCallback: callback];
    [callback release];
}

#ifdef WL_SURFACE_PREFERRED_BUFFER_SCALE_SINCE_VERSION
static void surface_offset_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    int32_t dx,
    int32_t dy
) {
    // Since v5, attach's own x/y arguments are deprecated (must be
    // sent as 0) in favor of this request; owl already ignores
    // attach's x/y the same way, so ignore this too.
}
#endif

static const struct wl_surface_interface surface_interface = {
    .destroy = surface_destroy_handler,
    .attach = surface_attach_handler,
    .damage = surface_damage_handler,
    .commit = surface_commit_handler,
    .frame = surface_frame_handler,
    .set_opaque_region = surface_set_opaque_region_handler,
    .set_input_region = surface_set_input_region_handler,
    .set_buffer_scale = surface_set_buffer_scale_handler,
    .set_buffer_transform = surface_set_buffer_transform_handler,
    .damage_buffer = surface_damage_buffer_handler,
#ifdef WL_SURFACE_PREFERRED_BUFFER_SCALE_SINCE_VERSION
    .offset = surface_offset_handler
#endif
};

- (id) initWithResource: (struct wl_resource *) resource {
    self = [super initWithFrame: NSZeroRect];
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &surface_interface,
        [self retain],
        surface_destroy
    );
    _callbacks = [NSMutableArray new];
    _presentationFeedbacks = [NSMutableArray new];
    _currentState = [OwlSurfaceState new];
    _pendingState = [OwlSurfaceState new];

#ifdef WL_SURFACE_PREFERRED_BUFFER_SCALE_SINCE_VERSION
    if (wl_resource_get_version(resource) >= WL_SURFACE_PREFERRED_BUFFER_SCALE_SINCE_VERSION) {
        wl_surface_send_preferred_buffer_scale(resource, 1);
    }
    if (wl_resource_get_version(resource) >= WL_SURFACE_PREFERRED_BUFFER_TRANSFORM_SINCE_VERSION) {
        wl_surface_send_preferred_buffer_transform(resource, WL_OUTPUT_TRANSFORM_NORMAL);
    }
#endif

    return self;
}

- (void) dealloc {
    [self tearDownGL];
    [_callbacks release];
    [_presentationFeedbacks release];
    [_currentState release];
    [_pendingState release];
    [super dealloc];
}

- (id<OwlSurfaceRole>) role {
    return _role;
}

- (void) setRole: (id<OwlSurfaceRole>) newRole {
    _role = newRole;
}

- (NSImage *) createCursorImage {
    OwlBuffer *buffer = [_currentState buffer];
    if (buffer == nil) {
        return nil;
    }
    return [buffer createNSImage];
}

- (OwlPointer *) pointer {
    struct wl_client *client = wl_resource_get_client(_resource);
    return [OwlPointer pointerForClient: client];
}

- (OwlKeyboard *) keyboard {
    struct wl_client *client = wl_resource_get_client(_resource);
    return [OwlKeyboard keyboardForClient: client];
}

- (NSPoint) pointOfEvent: (NSEvent *) event {
    NSPoint point = [event locationInWindow];
    point = [self convertPoint: point fromView: nil];
    point.y = [self bounds].size.height - point.y;
    return point;
}

- (void) mouseEntered: (NSEvent *) event {
    [[self window] setAcceptsMouseMovedEvents: YES];
    NSPoint point = [self pointOfEvent: event];
    if (!_mouseIsInside) {
        [[self pointer] sendEnterSurface: self atPoint: point];
        _mouseIsInside = YES;
    } else {
        // We believe the mouse to already be inside, and now
        // we get an enter event again. No need to send an enter
        // event to our client, but we do need to send the new
        // position, so fake a move event.
        [[self pointer] sendMotionAtPoint: point];
    }
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) ensureMouseIsInside: (NSEvent *) event {
    if (!_mouseIsInside) {
        // We haven't been told the mouse is inside our view,
        // but apparently it is. Fake an enter event.
        [self mouseEntered: event];
    }
}

- (void) mouseMoved: (NSEvent *) event {
    NSPoint point = [self pointOfEvent: event];
    // See whether the mouse is really inside our view.
    // If it's outside our view, stop receiving mouse events.
    if (!NSPointInRect(point, [self bounds])) {
        [[self window] setAcceptsMouseMovedEvents: NO];
        return;
    }

    [self ensureMouseIsInside: event];
    [[self pointer] sendMotionAtPoint: point];
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) mouseDragged: (NSEvent *) event {
    [self mouseMoved: event];
}

- (void) mouseExited: (NSEvent *) event {
    _mouseIsInside = NO;
    [[self window] setAcceptsMouseMovedEvents: NO];
    [[self pointer] sendLeaveSurface: self];
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) mouseDown: (NSEvent *) event {
    // The client matches its mouse bindings against the exact
    // modifier state, so make sure ours isn't stale before it
    // interprets the click.
    [[self keyboard] reconcileModifierFlags: [event modifierFlags]];
    [self ensureMouseIsInside: event];
    [[self pointer] sendButton: BTN_LEFT isPressed: YES];
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) mouseUp: (NSEvent *) event {
    [self ensureMouseIsInside: event];
    [[self pointer] sendButton: BTN_LEFT isPressed: NO];
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) rightMouseDown: (NSEvent *) event {
    [[self keyboard] reconcileModifierFlags: [event modifierFlags]];
    [self ensureMouseIsInside: event];
    [[self pointer] sendButton: BTN_RIGHT isPressed: YES];
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) rightMouseUp: (NSEvent *) event {
    [self ensureMouseIsInside: event];
    [[self pointer] sendButton: BTN_RIGHT isPressed: NO];
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) rightMouseDragged: (NSEvent *) event {
    [self mouseMoved: event];
}

- (void) scrollWheel: (NSEvent *) event {
    [[self keyboard] reconcileModifierFlags: [event modifierFlags]];
    [self ensureMouseIsInside: event];
    [[self pointer] sendScrollByX: [event deltaX] byY: [event deltaY]];
    [[OwlServer sharedServer] flushClientsLater];
}

- (BOOL) acceptsFirstResponder {
    return YES;
}

- (void) keyDown: (NSEvent *) event {
    OwlKeyboard *keyboard = [self keyboard];
    if (keyboard == nil) {
        return;
    }
    [keyboard reconcileModifierFlags: [event modifierFlags]];
    if ([event modifierFlags] & NSCommandKeyMask) {
        // Command chords belong to the compositor (they are our
        // menu shortcuts), so don't type them into the client.
        // Cocoa would not deliver the matching keyUp anyway,
        // which would leave the key stuck down and autorepeating
        // in the client.
        [[OwlServer sharedServer] flushClientsLater];
        return;
    }
    // Don't forward Cocoa's autorepeat to version 4+ keyboards:
    // those clients repeat keys themselves based on the
    // repeat_info event we send them. Older clients rely on
    // the compositor repeating, so let repeats through.
    if ([event isARepeat]
        && wl_resource_get_version([keyboard resource]) >= 4) {
        return;
    }
    [keyboard sendKey: [event keyCode] isPressed: YES];
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) keyUp: (NSEvent *) event {
    OwlKeyboard *keyboard = [self keyboard];
    if (keyboard == nil) {
        return;
    }
    [keyboard reconcileModifierFlags: [event modifierFlags]];
    [keyboard sendKey: [event keyCode] isPressed: NO];
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) flagsChanged: (NSEvent *) event {
    [[self keyboard] handleFlagsChanged: event];
    [[OwlServer sharedServer] flushClientsLater];
}

// The Edit menu items send these to the first responder, which
// is us whenever a client surface is focused. We cannot read or
// write the client's selection ourselves, so we type the keys
// the client binds its own clipboard actions to.
- (IBAction) copy: (id) sender {
    [[self keyboard] sendCopyKey];
    [[OwlServer sharedServer] flushClientsLater];
}

- (IBAction) paste: (id) sender {
    [[self keyboard] sendPasteKey];
    [[OwlServer sharedServer] flushClientsLater];
}

@end
