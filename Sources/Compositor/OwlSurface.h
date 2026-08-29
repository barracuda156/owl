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

#import <Cocoa/Cocoa.h>
#import <wayland-server.h>

@class OwlBuffer;
@class OwlOutput;
@class OwlPointer;
@class OwlSurfaceState;
@class OwlWpPresentationFeedback;
@class OwlWpViewport;

@protocol OwlSurfaceRole

- (void) map;
- (void) unmap;
- (void) update;

@end

@interface OwlSurface : NSView <NSTextInputClient> {
    struct wl_resource *_resource;
    NSOpenGLContext *_openGLContext;

    // The composition (preedit) string the Cocoa input context has
    // going on this view, mirrored to the client's text-input as
    // preedit_string; nil when no composition is active. Whether
    // the input context consumed the key event being interpreted is
    // tracked so -keyDown: knows to skip the raw key path.
    NSString *_markedText;
    BOOL _imeHandledKeyEvent;

    // Mouse tracking rectangle.
    NSTrackingRectTag _trackingRectTag;
    // Sadly, we cannot trust Cocoa to always deliver us
    // -mouseEntered: before -mouseMoved:, so keep our
    // own track of whether we think the mouse is inside.
    BOOL _mouseIsInside;
    // How many mouse buttons are currently held down. While
    // nonzero the client has an implicit grab: the tracking
    // rectangle may fire -mouseExited: mid-drag, but sending
    // leave would break e.g. text selection, so we defer it
    // until the last button is released.
    NSUInteger _buttonsDown;
    BOOL _exitedDuringDrag;

    // The view size at the time of the last window-shadow
    // invalidation. The shadow shape only depends on the surface
    // extents, so recomputing it on every -drawRect: is wasted
    // work; on 10.6/PPC the WindowServer's alpha-scan of a large
    // transparent window per frame is expensive enough to stall
    // the whole compositor during menu interaction.
    NSSize _lastShadowInvalidationSize;

    // Callbacks to be sent when we draw a frame.
    // These are first collected as a part of a pending
    // state, and added to this array on a commit. Once
    // added, the callbacks stay in this array no matter
    // further state changes and commits, only to be sent
    // out during the next -drawRect: call.
    NSMutableArray *_callbacks;

    // wp_presentation feedbacks, collected and moved here
    // the same way as the callbacks above, except that a
    // commit that supersedes a still-undrawn one discards
    // the queued feedbacks instead of keeping them: they
    // complete with either presented or discarded.
    NSMutableArray *_presentationFeedbacks;

    // The current state of this surface. This includes
    // things such as the attached buffer and an array
    // of damaged rects (compared to the previous frame).
    OwlSurfaceState *_currentState;
    // As the surface state in Wayland is double-buffered,
    // we store the pending state separately while it is
    // being built. This will become the new current state
    // on the next commit.
    OwlSurfaceState *_pendingState;
    id<OwlSurfaceRole> _role;

    // The wp_viewport attached to this surface, if any. Not
    // retained: the viewport resource owns the object, and clears
    // this pointer when it is destroyed.
    OwlWpViewport *_viewport;

    // The display this surface currently believes it is on, for
    // wl_surface.enter/leave. _hasCurrentOutputDisplayID is NO until
    // the surface's view first ends up in a window on some screen.
    BOOL _hasCurrentOutputDisplayID;
    uint32_t _currentOutputDisplayID;
}

- (id) initWithResource: (struct wl_resource *) resource;

- (struct wl_resource *) resource;

- (id<OwlSurfaceRole>) role;
- (void) setRole: (id<OwlSurfaceRole>) newRole;

- (void) setPendingGeometry: (NSRect) geometry;

// The current window geometry, in surface-local coordinates
// (y down from the top-left corner), clamped to the surface
// extents. Falls back to the surface's own bounds if
// set_window_geometry was never called (i.e. no explicit geometry
// was negotiated yet).
- (NSRect) windowGeometry;

// Reinstall the mouse tracking rectangle. The rect is registered
// with the window in window coordinates, so this must be called
// whenever the view is moved or resized within its window (the
// surface roles move the view around to clip CSD shadow margins).
- (void) updateTrackingRect;

/* Returns an NSImage of the current buffer content (for cursor use) */
- (NSImage *) createCursorImage;

/* Send out and clear any pending frame callbacks. */
- (void) fireCallbacks;

/* Queue a wp_presentation feedback for the next commit. */
- (void) addPresentationFeedback: (OwlWpPresentationFeedback *) feedback;

/* Complete and clear the queued presentation feedbacks. */
- (void) firePresentationFeedbacksPresented;
- (void) discardPresentationFeedbacks;

/* wp_viewport support. The viewport object registers itself here
 * (each surface can have at most one), writes the crop and scale
 * values into the pending state through the setters below, and
 * lets us know when it is destroyed. */
- (BOOL) hasViewport;
- (void) setViewport: (OwlWpViewport *) viewport;
- (void) viewportWasDestroyed;

- (void) setPendingViewportSource: (NSRect) source;
- (void) unsetPendingViewportSource;
- (void) setPendingViewportDestination: (NSSize) destination;
- (void) unsetPendingViewportDestination;

/* wp_alpha_modifier support: like all surface state, the
 * multiplier is double-buffered and takes effect on commit. */
- (void) setPendingAlphaMultiplier: (double) alphaMultiplier;

/* ext_background_effect_v1 support: like all surface state, this is
 * double-buffered and takes effect on commit. Unlike the alpha
 * multiplier, applying it is a window-level property change rather
 * than something that needs a repaint. */
- (void) setPendingBlurEnabled: (BOOL) enabled;

/* Abandon any composition the Cocoa input context has on this
 * view; called by text-input when the client disables its text
 * input or the keyboard focus leaves. */
- (void) clearMarkedText;

- (OwlPointer *) pointer;

/* Whether this surface believes it has the pointer inside (i.e.
 * holds the pointer focus of its client). */
- (BOOL) mouseIsInside;

/* If the given surface holds the global pointer focus, send it a
 * pointer leave and clear the focus, so that the surface now under
 * the cursor re-enters on its next event. No-op for any other
 * surface. Roles call this when their window goes away while the
 * cursor is (or may be) inside it — Cocoa delivers no -mouseExited:
 * for that. */
+ (void) relinquishPointerFocusOf: (OwlSurface *) surface;

/* Recompute which output (if any) this surface is on and send
 * wl_surface.enter/leave for any change, fanned over every wl_output
 * this surface's client has bound. Called when the view's window
 * changes, when that window's screen changes, and once per surface
 * from OwlOutput's hot-plug handler (a window can end up on a
 * different screen there too, e.g. its screen was unplugged). */
- (void) updateOutputEnterLeave;

/* Fan -updateOutputEnterLeave over every live surface. */
+ (void) updateOutputEnterLeaveForAllSurfaces;

/* Send wl_surface.enter on a freshly bound wl_output resource for
 * every one of that client's surfaces already on its display.
 * -updateOutputEnterLeave can only reach wl_output resources that
 * exist when the display ID changes, so a bind that arrives later
 * (nothing orders binds before surface mapping, and at hot-plug the
 * enter/leave fan-out necessarily runs before any client has seen
 * the new global) would otherwise never receive its enter. */
+ (void) sendRetroactiveEnterForOutput: (OwlOutput *) output;

@end
