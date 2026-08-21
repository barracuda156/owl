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
#import "OwlWpViewporter.h"
#import "OwlWpFractionalScaleManagerV1.h"
#import "OwlPointer.h"
#import "OwlKeyboard.h"
#import "OwlZwpKeyboardShortcutsInhibitManagerV1.h"
#import "OwlZwpPointerConstraintsV1.h"
#import "OwlZwpTextInputManagerV3.h"
#import "OwlServer.h"
#import "OwlBuffer.h"
#import "OwlSurfaceState.h"
#import "OwlRegion.h"
#import "OwlWlDataDevice.h"
#import "OwlDragDataSource.h"
#import "OwlFeatures.h"
#import "viewporter.h"
#import <wayland-server.h>
#import <Cocoa/Cocoa.h>
#import <math.h>


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
    // coordinates are the same as surface coordinates. (With a
    // wp_viewport attached they do differ, but then any damage
    // triggers a full repaint, so conflating the two is harmless.)
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
    // The protocol requires the effective geometry to be clamped
    // to the surface extents; without this, a client could make us
    // size its window to a rect its buffer cannot fill. Only the
    // extents matter for the intersection, so the differing y
    // directions of the two rects are harmless here.
    geometry = NSIntersectionRect(geometry, [self bounds]);
    if (NSIsEmptyRect(geometry)) {
        return [self bounds];
    }
    return geometry;
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

// Whether this surface accepts pointer input at the given point
// (in surface-local coordinates), per its wl_surface input region.
- (BOOL) acceptsPointerInputAtPoint: (NSPoint) point {
    NSData *region = [_currentState inputRegion];
    if (region == nil) {
        // No region set: the whole surface accepts input.
        return YES;
    }
    return [OwlRegion ops: region containPoint: point];
}

- (BOOL) acceptsAnyPointerInput {
    NSData *region = [_currentState inputRegion];
    if (region == nil) {
        return YES;
    }
    return [OwlRegion opsCanEverContainPoints: region];
}

// Honor the input region during hit testing: returning nil makes
// Cocoa fall through to whatever is underneath, e.g. the parent
// surface below an input-transparent subsurface overlay (foot's
// scrollback indicator sets an empty input region and aborts if it
// receives pointer focus anyway).
- (NSView *) hitTest: (NSPoint) point {
    NSView *result = [super hitTest: point];
    if (result != self) {
        // A subview (e.g. a subsurface) was hit; its own hit test
        // has already had its say.
        return result;
    }
    NSPoint local = [self convertPoint: point fromView: [self superview]];
    local.y = [self bounds].size.height - local.y;
    if (![self acceptsPointerInputAtPoint: local]) {
        return nil;
    }
    return result;
}

- (void) updateTrackingRect {
    if (_trackingRectTag != 0) {
        [self removeTrackingRect: _trackingRectTag];
        _trackingRectTag = 0;
    }
    if (![self acceptsAnyPointerInput]) {
        // Fully input-transparent: no enter/leave events either.
        return;
    }
    _trackingRectTag = [self addTrackingRect: [self bounds]
                                       owner: self
                                    userData: NULL
                                assumeInside: NO];
}

- (BOOL) hasViewport {
    return _viewport != nil;
}

- (void) setViewport: (OwlWpViewport *) viewport {
    _viewport = viewport;
}

- (void) viewportWasDestroyed {
    _viewport = nil;
    // Destroying the viewport removes the crop and scale state;
    // like any other surface state change, this takes effect on
    // the next commit.
    [_pendingState unsetViewportSource];
    [_pendingState unsetViewportDestination];
}

- (void) setPendingViewportSource: (NSRect) source {
    [_pendingState setViewportSource: source];
}

- (void) unsetPendingViewportSource {
    [_pendingState unsetViewportSource];
}

- (void) setPendingViewportDestination: (NSSize) destination {
    [_pendingState setViewportDestination: destination];
}

- (void) unsetPendingViewportDestination {
    [_pendingState unsetViewportDestination];
}

- (void) setPendingAlphaMultiplier: (double) alphaMultiplier {
    [_pendingState setAlphaMultiplier: alphaMultiplier];
}

// Enforce the wp_viewport rules that are only checked at commit
// time, against the buffer that is about to be applied. Returns NO
// after posting a protocol error, in which case the pending state
// must not be applied.
- (BOOL) validatePendingViewportWithBuffer: (OwlBuffer *) buffer {
    if (_viewport == nil || ![_pendingState viewportSourceIsSet]) {
        return YES;
    }
    NSRect source = [_pendingState viewportSource];
    if (![_pendingState viewportDestinationIsSet]
        && (source.size.width != floor(source.size.width)
            || source.size.height != floor(source.size.height)))
    {
        wl_resource_post_error(
            [_viewport resource],
            WP_VIEWPORT_ERROR_BAD_SIZE,
            "non-integer source size %gx%g with no destination set",
            (double) source.size.width,
            (double) source.size.height
        );
        return NO;
    }
    // The source rectangle's origin and size are known to be
    // non-negative and positive respectively (set_source checks),
    // so only the far edges can stick out of the buffer.
    if (buffer != nil) {
        NSSize bufferSize = [buffer size];
        if (source.origin.x + source.size.width > bufferSize.width
            || source.origin.y + source.size.height > bufferSize.height)
        {
            wl_resource_post_error(
                [_viewport resource],
                WP_VIEWPORT_ERROR_OUT_OF_BUFFER,
                "source rectangle (%g, %g) %gx%g is outside of the %gx%g buffer",
                (double) source.origin.x,
                (double) source.origin.y,
                (double) source.size.width,
                (double) source.size.height,
                (double) bufferSize.width,
                (double) bufferSize.height
            );
            return NO;
        }
    }
    return YES;
}

- (void) commit {
    OwlBuffer *oldBuffer = [_currentState buffer];
    OwlBuffer *newBuffer = [_pendingState buffer];
    BOOL oldBufferNeedsGL = [oldBuffer needsGLForRendering];
    BOOL newBufferNeedsGL = [newBuffer needsGLForRendering];

    if (![self validatePendingViewportWithBuffer: newBuffer]) {
        // A protocol error has been posted and the client is on
        // its way out; don't apply the broken state.
        return;
    }

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

    // Compared by pointer below, never dereferenced: the old data
    // may die with the old state.
    NSData *oldInputRegion = [_currentState inputRegion];

    // Whether this commit crops and scales differently from the
    // previous one; computed before the swap while both states
    // are still around.
    BOOL viewportChanged = ![_pendingState hasSameViewportAs: _currentState];
    // Same for the alpha multiplier: a change repaints everything.
    BOOL alphaChanged = [_pendingState alphaMultiplier]
        != [_currentState alphaMultiplier];

    // Actually set the pending state as our new state.
    [_currentState release];
    _currentState = _pendingState;
    _pendingState = [OwlSurfaceState alloc];
    _pendingState = [_pendingState initWithPreviousState: _currentState];

    if ([_currentState inputRegion] != oldInputRegion) {
        // The input region changed; reconsider the tracking rect.
        [self updateTrackingRect];
    }

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

    // With a wp_viewport attached, the surface size decouples from
    // the buffer size: the destination size wins if set, then the
    // source rectangle size, and only then the buffer size.
    NSSize surfaceSize;
    BOOL viewportActive = [_currentState viewportSourceIsSet]
        || [_currentState viewportDestinationIsSet];
    if ([_currentState viewportDestinationIsSet]) {
        surfaceSize = [_currentState viewportDestination];
    } else if ([_currentState viewportSourceIsSet]) {
        surfaceSize = [_currentState viewportSource].size;
    } else {
        surfaceSize = [newBuffer size];
    }

    if (!NSEqualSizes([self frame].size, surfaceSize)) {
        [self setFrameSize: surfaceSize];
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
    if (damageAll || viewportChanged || alphaChanged) {
        [self setNeedsDisplay: YES];
        willRedraw = YES;
    } else if (viewportActive) {
        // Damage is in surface coordinates, but the view shows a
        // scaled crop of the buffer; mapping the rects through the
        // viewport is not worth the trouble, so any damage at all
        // repaints everything.
        if ([[_currentState damage] count] > 0) {
            [self setNeedsDisplay: YES];
            willRedraw = YES;
        }
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

    // Honor the wp_alpha_modifier_surface_v1 multiplier by drawing
    // the buffer through a transparency layer. This covers the
    // CG-drawn buffer types (shm, single-pixel); GL-composited
    // IOSurface buffers bypass the CG context and keep full
    // opacity. Not available on GNUstep, which has no CGContext.
#ifdef OWL_PLATFORM_APPLE
    double alpha = [_currentState alphaMultiplier];
    CGContextRef context = NULL;
    if (alpha < 1.0) {
        context = [[NSGraphicsContext currentContext] graphicsPort];
        CGContextSaveGState(context);
        CGContextSetAlpha(context, alpha);
        CGContextBeginTransparencyLayer(context, NULL);
    }
#endif

    if ([_currentState viewportSourceIsSet]) {
        [[_currentState buffer] drawInRect: [self bounds]
                                  fromRect: [_currentState viewportSource]];
    } else {
        [[_currentState buffer] drawInRect: [self bounds]];
    }

#ifdef OWL_PLATFORM_APPLE
    if (context != NULL) {
        CGContextEndTransparencyLayer(context);
        CGContextRestoreGState(context);
    }
#endif

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
    OwlSurface *self = wl_resource_get_user_data(resource);
    NSData *ops = nil;
    if (region_resource != NULL) {
        OwlRegion *region = wl_resource_get_user_data(region_resource);
        // Snapshot: the client may destroy the region object right
        // after this request, but the input region is double-buffered
        // state that outlives it.
        ops = [region opsSnapshot];
    }
    [self->_pendingState setInputRegion: ops];
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

    // Accept files and text dragged in from other applications;
    // they are forwarded to the client as wl_data_device
    // drag-and-drop events.
    [self registerForDraggedTypes:
              [NSArray arrayWithObjects: NSFilenamesPboardType,
                                         NSStringPboardType,
                                         nil]];

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
    [_markedText release];
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

// Whether this surface holds a keyboard shortcuts inhibitor, in
// which case Command chords are typed into the client rather than
// treated as compositor menu shortcuts.
- (BOOL) shortcutsInhibited {
    return [OwlZwpKeyboardShortcutsInhibitManagerV1
        shortcutsInhibitedForSurfaceResource: _resource];
}

- (void) reconcileModifiersForEvent: (NSEvent *) event {
    [[self keyboard] reconcileModifierFlags: [event modifierFlags]
                             includeCommand: [self shortcutsInhibited]];
}

- (NSPoint) pointOfEvent: (NSEvent *) event {
    NSPoint point = [event locationInWindow];
    point = [self convertPoint: point fromView: nil];
    point.y = [self bounds].size.height - point.y;
    return point;
}

- (void) mouseEntered: (NSEvent *) event {
    _exitedDuringDrag = NO;
    [[self window] setAcceptsMouseMovedEvents: YES];
    NSPoint point = [self pointOfEvent: event];
    if (![self acceptsPointerInputAtPoint: point]) {
        // Input-transparent here (e.g. an overlay subsurface with
        // an empty input region): the pointer focus stays with
        // whatever surface is underneath.
        return;
    }
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

- (BOOL) mouseIsInside {
    return _mouseIsInside;
}

- (void) ensureMouseIsInside: (NSEvent *) event {
    if (!_mouseIsInside) {
        // We haven't been told the mouse is inside our view,
        // but apparently it is. Fake an enter event.
        [self mouseEntered: event];
    }
}

// The surface point nearest to the given one that is comfortably
// inside our bounds, for warping a confined pointer back in.
- (NSPoint) nearestInBoundsPoint: (NSPoint) point {
    NSSize size = [self bounds].size;
    if (point.x < 1.0) {
        point.x = 1.0;
    }
    if (point.x > size.width - 1.0) {
        point.x = size.width - 1.0;
    }
    if (point.y < 1.0) {
        point.y = 1.0;
    }
    if (point.y > size.height - 1.0) {
        point.y = size.height - 1.0;
    }
    return point;
}

- (void) mouseMoved: (NSEvent *) event {
    if ([OwlZwpPointerConstraintsV1
            hasActiveLockForSurfaceResource: _resource]) {
        // The pointer is locked: the cursor is pinned, but deltas
        // keep coming. Only relative motion goes to the client.
        [self ensureMouseIsInside: event];
        [[self pointer] sendRelativeMotionDeltaX: [event deltaX]
                                          deltaY: [event deltaY]];
        [[OwlServer sharedServer] flushClientsLater];
        return;
    }

    NSPoint point = [self pointOfEvent: event];
    // See whether the mouse is really inside our view.
    // If it's outside our view, stop receiving mouse events.
    if (!NSPointInRect(point, [self bounds])) {
        if ([OwlZwpPointerConstraintsV1
                hasActiveConfinementForSurfaceResource: _resource]) {
            // Confined: put the cursor back at the nearest point
            // inside the surface instead of letting it escape.
            [OwlZwpPointerConstraintsV1
                warpPointerToSurface: self
                               point: [self nearestInBoundsPoint: point]];
            return;
        }
        [[self window] setAcceptsMouseMovedEvents: NO];
        return;
    }

    [self ensureMouseIsInside: event];
    [[self pointer] sendMotionAtPoint: point
                               deltaX: [event deltaX]
                               deltaY: [event deltaY]];
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) mouseDragged: (NSEvent *) event {
    if ([OwlZwpPointerConstraintsV1
            hasActiveLockForSurfaceResource: _resource]) {
        [self ensureMouseIsInside: event];
        [[self pointer] sendRelativeMotionDeltaX: [event deltaX]
                                          deltaY: [event deltaY]];
        [[OwlServer sharedServer] flushClientsLater];
        return;
    }
    NSPoint point = [self pointOfEvent: event];
    if (!NSPointInRect(point, [self bounds])
        && [OwlZwpPointerConstraintsV1
               hasActiveConfinementForSurfaceResource: _resource]) {
        // Confined: hold the line even mid-drag. Tracking rects
        // don't reliably fire -mouseExited: while a button is
        // down, so this is where a dragging escape gets caught;
        // the client sees motion clamped to the surface.
        point = [self nearestInBoundsPoint: point];
        [OwlZwpPointerConstraintsV1 warpPointerToSurface: self
                                                   point: point];
    }
    // Unlike -mouseMoved:, don't bail out when the point is
    // outside our bounds: the client holds an implicit grab, and
    // motion must keep flowing (with out-of-bounds coordinates if
    // need be) so that e.g. a text selection can auto-scroll.
    [self ensureMouseIsInside: event];
    [[self pointer] sendMotionAtPoint: point
                               deltaX: [event deltaX]
                               deltaY: [event deltaY]];
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) mouseExited: (NSEvent *) event {
    if ([OwlZwpPointerConstraintsV1
            hasActiveConfinementForSurfaceResource: _resource]) {
        // Confined: the cursor left the surface; bring it right
        // back rather than delivering a leave.
        NSPoint point = [self nearestInBoundsPoint: [self pointOfEvent: event]];
        [OwlZwpPointerConstraintsV1 warpPointerToSurface: self
                                                   point: point];
        return;
    }
    if (_buttonsDown > 0) {
        // Keep the implicit grab: deliver the leave once the
        // buttons are released instead.
        _exitedDuringDrag = YES;
        return;
    }
    _mouseIsInside = NO;
    [[self window] setAcceptsMouseMovedEvents: NO];
    [[self pointer] sendLeaveSurface: self];
    [[OwlServer sharedServer] flushClientsLater];
}

// Called after a button release; if the tracking rectangle fired
// -mouseExited: while we were keeping the implicit grab alive,
// deliver the deferred leave now that the grab is over.
- (void) buttonReleasedForEvent: (NSEvent *) event {
    if (_buttonsDown > 0) {
        _buttonsDown--;
    }
    if (_buttonsDown != 0 || !_exitedDuringDrag) {
        return;
    }
    _exitedDuringDrag = NO;
    if (!NSPointInRect([self pointOfEvent: event], [self bounds])) {
        [self mouseExited: event];
    }
}

- (void) mouseDown: (NSEvent *) event {
    // The client matches its mouse bindings against the exact
    // modifier state, so make sure ours isn't stale before it
    // interprets the click.
    [self reconcileModifiersForEvent: event];
    [self ensureMouseIsInside: event];
    _buttonsDown++;
    [[self pointer] sendButton: BTN_LEFT isPressed: YES];
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) mouseUp: (NSEvent *) event {
    [self ensureMouseIsInside: event];
    [[self pointer] sendButton: BTN_LEFT isPressed: NO];
    [self buttonReleasedForEvent: event];
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) rightMouseDown: (NSEvent *) event {
    [self reconcileModifiersForEvent: event];
    [self ensureMouseIsInside: event];
    _buttonsDown++;
    [[self pointer] sendButton: BTN_RIGHT isPressed: YES];
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) rightMouseUp: (NSEvent *) event {
    [self ensureMouseIsInside: event];
    [[self pointer] sendButton: BTN_RIGHT isPressed: NO];
    [self buttonReleasedForEvent: event];
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) rightMouseDragged: (NSEvent *) event {
    [self mouseDragged: event];
}

- (void) otherMouseDown: (NSEvent *) event {
    // Cocoa reports every button beyond left/right through this
    // path; we only map the middle button (primary-selection paste
    // in foot et al.) and ignore any further extra buttons, which
    // have no established evdev mapping to forward.
    if ([event buttonNumber] != 2) {
        return;
    }
    [self reconcileModifiersForEvent: event];
    [self ensureMouseIsInside: event];
    _buttonsDown++;
    [[self pointer] sendButton: BTN_MIDDLE isPressed: YES];
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) otherMouseUp: (NSEvent *) event {
    if ([event buttonNumber] != 2) {
        return;
    }
    [self ensureMouseIsInside: event];
    [[self pointer] sendButton: BTN_MIDDLE isPressed: NO];
    [self buttonReleasedForEvent: event];
    [[OwlServer sharedServer] flushClientsLater];
}

- (void) otherMouseDragged: (NSEvent *) event {
    if ([event buttonNumber] != 2) {
        return;
    }
    [self mouseDragged: event];
}

- (void) scrollWheel: (NSEvent *) event {
    [self reconcileModifiersForEvent: event];
    [self ensureMouseIsInside: event];
    [[self pointer] sendScrollByX: [event deltaX] byY: [event deltaY]];
    [[OwlServer sharedServer] flushClientsLater];
}

- (BOOL) acceptsFirstResponder {
    return YES;
}

// A click on an inactive owl window should not just activate it,
// but also reach the client, the way clicks reach surfaces on any
// other Wayland compositor. In particular, while a popup holds the
// key status, a click back in the main window must get through for
// the client's grab logic to dismiss the popup.
- (BOOL) acceptsFirstMouse: (NSEvent *) event {
    return YES;
}

- (void) viewDidMoveToWindow {
    // The backing scale of a surface is only really known once its
    // view ends up in a window; let fractional-scale re-check.
    [OwlWpFractionalScaleManagerV1 notifySurfaceMovedToWindow: self];
    // A pointer constraint created before the surface had a window
    // gets its chance to activate now: if the window is already
    // key, no NSWindowDidBecomeKeyNotification will ever fire.
    [OwlZwpPointerConstraintsV1 notifySurfaceMovedToWindow: self];
}

// Whether this key event should be offered to the Cocoa input
// context (for dead keys, non-Latin layouts, CJK composition)
// rather than forwarded raw. Only when the client asked for text
// via an enabled text-input, and never for chords that clients
// expect as key events.
- (BOOL) shouldRouteKeyEventToInputContext: (NSEvent *) event {
    if ([event modifierFlags] & (NSCommandKeyMask | NSControlKeyMask)) {
        return NO;
    }
    if ([self shortcutsInhibited]) {
        return NO;
    }
    return [OwlZwpTextInputManagerV3
        hasEnabledTextInputForSurfaceResource: _resource];
}

- (void) keyDown: (NSEvent *) event {
    OwlKeyboard *keyboard = [self keyboard];
    if (keyboard == nil) {
        return;
    }
    [self reconcileModifiersForEvent: event];
    if (([event modifierFlags] & NSCommandKeyMask)
        && ![self shortcutsInhibited]) {
        // Command chords belong to the compositor (they are our
        // menu shortcuts), so don't type them into the client.
        // Cocoa would not deliver the matching keyUp anyway,
        // which would leave the key stuck down and autorepeating
        // in the client.
        [[OwlServer sharedServer] flushClientsLater];
        return;
    }
    if ([self shouldRouteKeyEventToInputContext: event]) {
        // Let the input context interpret the key. Text lands in
        // -insertText:/-setMarkedText: and reaches the client as
        // commit_string/preedit_string; the raw key is then not
        // sent (and its keyUp is suppressed automatically, since
        // the press was never recorded). Non-text keys come back
        // through -doCommandBySelector:, which leaves the flag
        // unset, and fall through to the raw path below.
        _imeHandledKeyEvent = NO;
        [self interpretKeyEvents: [NSArray arrayWithObject: event]];
        if (_imeHandledKeyEvent) {
            [[OwlServer sharedServer] flushClientsLater];
            return;
        }
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
    [self reconcileModifiersForEvent: event];
    [keyboard sendKey: [event keyCode] isPressed: NO];
    [[OwlServer sharedServer] flushClientsLater];
}

- (BOOL) performKeyEquivalent: (NSEvent *) event {
    // Cocoa offers Command chords to the view hierarchy before the
    // menu bar gets them. Normally we decline, letting our menu
    // shortcuts work; but for a surface holding a keyboard
    // shortcuts inhibitor, the chord is typed into the client and
    // the menu never sees it. Only the focused surface may claim
    // the event: performKeyEquivalent visits every view, focused
    // or not.
    if (![self shortcutsInhibited]
        || [[self window] firstResponder] != self
        || [event type] != NSKeyDown) {
        return [super performKeyEquivalent: event];
    }
    [self keyDown: event];
    return YES;
}

- (void) flagsChanged: (NSEvent *) event {
    [self reconcileModifiersForEvent: event];
    [[OwlServer sharedServer] flushClientsLater];
}

/*
 * NSTextInputClient: how the Cocoa input context talks back when
 * -keyDown: hands it an event via -interpretKeyEvents:. Owl has no
 * text storage of its own — the document lives in the client — so
 * this is the minimal honest implementation: composition text is
 * mirrored to the client as text-input preedit, insertions as
 * commit strings, and everything document-shaped answers "unknown".
 */

// The input context speaks NSString or NSAttributedString
// depending on its mood; owl only ever wants the characters.
static NSString *plain_string(id string) {
    if ([string isKindOfClass: [NSAttributedString class]]) {
        return [string string];
    }
    return string;
}

// The protocol expresses preedit cursor positions as byte offsets
// into the UTF-8 text; Cocoa gives us UTF-16 code unit indices.
static int32_t byte_offset_for_index(NSString *string, NSUInteger index) {
    if (string == nil) {
        return 0;
    }
    if (index > [string length]) {
        index = [string length];
    }
    const char *prefix = [[string substringToIndex: index] UTF8String];
    if (prefix == NULL) {
        return 0;
    }
    return (int32_t) strlen(prefix);
}

- (void) clearMarkedText {
    if (_markedText == nil) {
        return;
    }
    [_markedText release];
    _markedText = nil;
#if defined(OWL_PLATFORM_APPLE) && MAC_OS_X_VERSION_MAX_ALLOWED >= 1060
    // Owl abandoned the composition (focus left, or the client
    // disabled its text input); the input context must not keep
    // its half, or the next keystroke would resume a composition
    // whose preedit the client already discarded.
    if ([self respondsToSelector: @selector(inputContext)]) {
        [[self inputContext] discardMarkedText];
    }
#endif
}

- (BOOL) hasMarkedText {
    return _markedText != nil;
}

- (NSRange) markedRange {
    if (_markedText == nil) {
        return NSMakeRange(NSNotFound, 0);
    }
    return NSMakeRange(0, [_markedText length]);
}

- (NSRange) selectedRange {
    // The document lives in the client; we cannot point into it.
    return NSMakeRange(NSNotFound, 0);
}

- (void) setMarkedText: (id) string
         selectedRange: (NSRange) selectedRange
      replacementRange: (NSRange) replacementRange
{
    _imeHandledKeyEvent = YES;
    NSString *text = plain_string(string);

    [_markedText release];
    if ([text length] > 0) {
        _markedText = [text copy];
    } else {
        _markedText = nil;
    }

    // selectedRange is relative to the marked text itself; the
    // protocol wants it as byte offsets into the UTF-8 preedit.
    int32_t cursorBegin = byte_offset_for_index(
        _markedText, selectedRange.location);
    int32_t cursorEnd = byte_offset_for_index(
        _markedText, selectedRange.location + selectedRange.length);

    [OwlZwpTextInputManagerV3 sendPreeditString: _markedText
                                    cursorBegin: cursorBegin
                                      cursorEnd: cursorEnd
                             forSurfaceResource: _resource];
}

// The pre-10.5 NSTextInput spelling, which GNUstep's (and old
// input managers') -interpretKeyEvents: machinery still uses.
- (void) setMarkedText: (id) string selectedRange: (NSRange) selectedRange {
    [self setMarkedText: string
          selectedRange: selectedRange
       replacementRange: NSMakeRange(NSNotFound, 0)];
}

- (void) unmarkText {
    // The input context wants the composition confirmed as-is.
    _imeHandledKeyEvent = YES;
    if (_markedText == nil) {
        return;
    }
    NSString *text = _markedText;
    _markedText = nil;
    [OwlZwpTextInputManagerV3 sendCommitString: text
                            forSurfaceResource: _resource];
    [text release];
}

- (void) insertText: (id) string replacementRange: (NSRange) replacementRange {
    _imeHandledKeyEvent = YES;
    [self clearMarkedText];
    // replacementRange is ignored: it indexes into a document we
    // don't have. IMEs pass {NSNotFound, 0} for plain insertion,
    // which is the case that matters.
    [OwlZwpTextInputManagerV3 sendCommitString: plain_string(string)
                            forSurfaceResource: _resource];
}

// The pre-10.5 spelling again, and also the path NSResponder's key
// binding tables use.
- (void) insertText: (id) string {
    [self insertText: string replacementRange: NSMakeRange(NSNotFound, 0)];
}

- (void) doCommandBySelector: (SEL) selector {
    // Non-text keys (arrows, Return, Backspace, Escape, Tab...)
    // come back from the input context as editing commands. Leave
    // _imeHandledKeyEvent unset: -keyDown: falls through to the
    // raw wl_keyboard path, which is what clients expect for these
    // keys. Deliberately not calling super, whose default would
    // beep on every "unhandled" command.
}

- (NSArray *) validAttributesForMarkedText {
    return [NSArray array];
}

- (NSAttributedString *) attributedSubstringForProposedRange: (NSRange) range
                                                 actualRange: (NSRangePointer) actualRange
{
    // No document to substring into.
    return nil;
}

- (NSUInteger) characterIndexForPoint: (NSPoint) point {
    return NSNotFound;
}

- (NSRect) firstRectForCharacterRange: (NSRange) range
                          actualRange: (NSRangePointer) actualRange
{
    // Place the IME candidate window at the cursor rectangle the
    // client gave its text-input, or at the surface's top-left
    // corner if it never did. The rectangle arrives in
    // surface-local coordinates (top-left origin); Cocoa wants
    // screen coordinates.
    NSRect rect;
    if (![OwlZwpTextInputManagerV3 getCursorRectangle: &rect
                                   forSurfaceResource: _resource]) {
        rect = NSMakeRect(0, 0, 1, 1);
    }
    NSRect viewRect = rect;
    viewRect.origin.y =
        [self bounds].size.height - rect.origin.y - rect.size.height;
    NSRect windowRect = [self convertRect: viewRect toView: nil];
    if ([self window] != nil) {
        windowRect.origin =
            [[self window] convertBaseToScreen: windowRect.origin];
    }
    return windowRect;
}

/* The rest of the pre-10.5 NSTextInput spellings, for input
 * machinery (10.5's NSInputManager, GNUstep) that predates
 * NSTextInputClient. */

- (NSRect) firstRectForCharacterRange: (NSRange) range {
    return [self firstRectForCharacterRange: range actualRange: NULL];
}

- (NSAttributedString *) attributedSubstringFromRange: (NSRange) range {
    return nil;
}

- (long) conversationIdentifier {
    return (long) self;
}

- (OwlWlDataDevice *) dataDevice {
    struct wl_client *client = wl_resource_get_client(_resource);
    return [OwlWlDataDevice dataDeviceForClient: client];
}

- (NSPoint) pointOfDraggingInfo: (id <NSDraggingInfo>) sender {
    NSPoint point = [self convertPoint: [sender draggingLocation]
                              fromView: nil];
    point.y = [self bounds].size.height - point.y;
    return point;
}

- (NSDragOperation) draggingEntered: (id <NSDraggingInfo>) sender {
    OwlWlDataDevice *dataDevice = [self dataDevice];
    if (dataDevice == nil) {
        return NSDragOperationNone;
    }

    OwlDragDataSource *dataSource = [OwlDragDataSource alloc];
    dataSource = [dataSource initWithPasteboard:
                                 [sender draggingPasteboard]];
    if ([[dataSource mimeTypes] count] == 0) {
        // Nothing on the drag pasteboard we can represent.
        [dataSource release];
        return NSDragOperationNone;
    }

    [dataDevice dndEnterSurface: self
                        atPoint: [self pointOfDraggingInfo: sender]
                 withDataSource: dataSource];
    // The offer holds on to the data source now.
    [dataSource release];
    [[OwlServer sharedServer] flushClientsLater];
    return NSDragOperationCopy;
}

- (NSDragOperation) draggingUpdated: (id <NSDraggingInfo>) sender {
    OwlWlDataDevice *dataDevice = [self dataDevice];
    if (![dataDevice isDndInProgress]) {
        return NSDragOperationNone;
    }
    [dataDevice dndMotionAtPoint: [self pointOfDraggingInfo: sender]];
    [[OwlServer sharedServer] flushClientsLater];
    return NSDragOperationCopy;
}

- (void) draggingExited: (id <NSDraggingInfo>) sender {
    [[self dataDevice] dndLeave];
    [[OwlServer sharedServer] flushClientsLater];
}

- (BOOL) prepareForDragOperation: (id <NSDraggingInfo>) sender {
    return [[self dataDevice] isDndInProgress];
}

- (BOOL) performDragOperation: (id <NSDraggingInfo>) sender {
    OwlWlDataDevice *dataDevice = [self dataDevice];
    if (![dataDevice isDndInProgress]) {
        return NO;
    }
    [dataDevice dndMotionAtPoint: [self pointOfDraggingInfo: sender]];
    [dataDevice dndDrop];
    [[OwlServer sharedServer] flushClientsLater];
    return YES;
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
