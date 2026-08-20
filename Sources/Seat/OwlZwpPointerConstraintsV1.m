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

#import "OwlZwpPointerConstraintsV1.h"
#import "OwlSurface.h"
#import "OwlServer.h"
#import "OwlFeatures.h"
#import "pointer-constraints-unstable-v1.h"

#ifdef OWL_PLATFORM_APPLE
    #import <ApplicationServices/ApplicationServices.h>
#endif


/* One zwp_locked_pointer_v1 or zwp_confined_pointer_v1, keyed to
 * the wl_surface it constrains. The wl_pointer argument is not
 * kept: owl has a single pointer per client. */
@interface OwlZwpPointerConstraint : NSObject {
@public
    struct wl_resource *_resource;
    struct wl_resource *_surfaceResource;
    struct wl_listener _surfaceDestroyListener;
    BOOL _isLock;
    uint32_t _lifetime;
    BOOL _active;
    // A oneshot constraint that has deactivated once; it stays
    // around until the client destroys it, but never activates
    // again.
    BOOL _dead;
    // The cursor position hint, in surface-local coordinates
    // (top-left origin), to warp to on unlock.
    BOOL _hintIsSet;
    NSPoint _hint;
}

- (id) initWithResource: (struct wl_resource *) resource
        surfaceResource: (struct wl_resource *) surfaceResource
                 isLock: (BOOL) isLock
               lifetime: (uint32_t) lifetime;

- (void) activate;
- (void) deactivate;

@end

@implementation OwlZwpPointerConstraint

static NSMutableArray *constraints;

+ (void) initialize {
    if (constraints == nil) {
        constraints = [[NSMutableArray alloc] initWithCapacity: 1];
    }
}

+ (OwlZwpPointerConstraint *) constraintForSurfaceResource:
    (struct wl_resource *) surfaceResource
{
    for (OwlZwpPointerConstraint *constraint in constraints) {
        if (constraint->_surfaceResource == surfaceResource) {
            return constraint;
        }
    }
    return nil;
}

- (OwlSurface *) surface {
    if (_surfaceResource == NULL) {
        return nil;
    }
    return wl_resource_get_user_data(_surfaceResource);
}

#ifdef OWL_PLATFORM_APPLE
// Whether the hardware cursor is currently over the surface's view.
static BOOL cursorIsOverSurface(OwlSurface *surface) {
    NSWindow *window = [surface window];
    if (window == nil) {
        return NO;
    }
    NSPoint basePoint = [window convertScreenToBase: [NSEvent mouseLocation]];
    NSPoint viewPoint = [surface convertPoint: basePoint fromView: nil];
    return NSPointInRect(viewPoint, [surface bounds]);
}
#endif

- (void) activate {
    if (_active || _dead || _surfaceResource == NULL) {
        return;
    }
    _active = YES;

    if (_isLock) {
#ifdef OWL_PLATFORM_APPLE
        OwlSurface *surface = [self surface];
        // Pin the cursor in place. If it is not currently over the
        // surface, first bring it to the middle, so that the pinned
        // position keeps delivering mouse events to the surface's
        // view; and make sure motion events flow at all, since with
        // the cursor pinned there may never be a mouseEntered to
        // turn them on.
        if (!cursorIsOverSurface(surface)) {
            NSSize size = [surface bounds].size;
            NSPoint center = NSMakePoint(size.width / 2, size.height / 2);
            [OwlZwpPointerConstraintsV1 warpPointerToSurface: surface
                                                       point: center];
        }
        [[surface window] setAcceptsMouseMovedEvents: YES];
        CGAssociateMouseAndMouseCursorPosition(false);
#endif
        zwp_locked_pointer_v1_send_locked(_resource);
    } else {
        zwp_confined_pointer_v1_send_confined(_resource);
    }
    [[OwlServer sharedServer] flushClientsLater];
}

// Undo the OS-level effects of an active lock without touching the
// protocol object; shared between deactivation and the paths where
// the resource or surface is already going away.
- (void) restorePointerAssociation {
#ifdef OWL_PLATFORM_APPLE
    if (_isLock) {
        CGAssociateMouseAndMouseCursorPosition(true);
    }
#endif
}

- (void) warpToHint {
    if (!_isLock || !_hintIsSet) {
        return;
    }
    OwlSurface *surface = [self surface];
    if (surface == nil) {
        return;
    }
    [OwlZwpPointerConstraintsV1 warpPointerToSurface: surface
                                               point: _hint];
}

- (void) deactivate {
    if (!_active) {
        return;
    }
    _active = NO;
    [self restorePointerAssociation];
    [self warpToHint];
    if (_isLock) {
        zwp_locked_pointer_v1_send_unlocked(_resource);
    } else {
        zwp_confined_pointer_v1_send_unconfined(_resource);
    }
    if (_lifetime == ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_ONESHOT) {
        _dead = YES;
    }
    [[OwlServer sharedServer] flushClientsLater];
}

static void constraint_surface_destroy_notify(
    struct wl_listener *listener,
    void *data
) {
    OwlZwpPointerConstraint *self = nil;
    for (OwlZwpPointerConstraint *constraint in constraints) {
        if (&constraint->_surfaceDestroyListener == listener) {
            self = constraint;
            break;
        }
    }
    if (self == nil) {
        return;
    }

    [self deactivate];
    self->_surfaceResource = NULL;
    wl_list_remove(&self->_surfaceDestroyListener.link);
    wl_list_init(&self->_surfaceDestroyListener.link);
}

static void constraint_destroy(struct wl_resource *resource) {
    OwlZwpPointerConstraint *self = wl_resource_get_user_data(resource);
    if (self->_active) {
        // The resource is going away, so no unlocked/unconfined
        // event; just undo the OS-level state. Destroying an
        // active lock is the usual way clients release the
        // pointer, so honor the cursor position hint.
        self->_active = NO;
        [self restorePointerAssociation];
        [self warpToHint];
    }
    [constraints removeObjectIdenticalTo: self];
    [self release];
}

static void constraint_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void locked_pointer_set_cursor_position_hint_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    wl_fixed_t surface_x,
    wl_fixed_t surface_y
) {
    OwlZwpPointerConstraint *self = wl_resource_get_user_data(resource);
    self->_hintIsSet = YES;
    self->_hint = NSMakePoint(
        wl_fixed_to_double(surface_x),
        wl_fixed_to_double(surface_y)
    );
}

static void constraint_set_region_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *region_resource
) {
    // Regions are not honored; the constraint area is always the
    // whole surface. That is also what a null region means, and
    // matches how games and VMs actually use the protocol.
}

static const struct zwp_locked_pointer_v1_interface locked_pointer_impl = {
    .destroy = constraint_destroy_handler,
    .set_cursor_position_hint = locked_pointer_set_cursor_position_hint_handler,
    .set_region = constraint_set_region_handler
};

static const struct zwp_confined_pointer_v1_interface confined_pointer_impl = {
    .destroy = constraint_destroy_handler,
    .set_region = constraint_set_region_handler
};

- (id) initWithResource: (struct wl_resource *) resource
        surfaceResource: (struct wl_resource *) surfaceResource
                 isLock: (BOOL) isLock
               lifetime: (uint32_t) lifetime
{
    _resource = resource;
    _surfaceResource = surfaceResource;
    _isLock = isLock;
    _lifetime = lifetime;
    _surfaceDestroyListener.notify = constraint_surface_destroy_notify;
    wl_resource_add_destroy_listener(
        surfaceResource,
        &_surfaceDestroyListener
    );
    [constraints addObject: self];

    wl_resource_set_implementation(
        resource,
        isLock ? (const void *) &locked_pointer_impl
               : (const void *) &confined_pointer_impl,
        [self retain],
        constraint_destroy
    );

    return self;
}

- (void) dealloc {
    if (_surfaceResource != NULL) {
        wl_list_remove(&_surfaceDestroyListener.link);
    }
    [super dealloc];
}

@end


@implementation OwlZwpPointerConstraintsV1

+ (BOOL) hasActiveLockForSurfaceResource:
    (struct wl_resource *) surfaceResource
{
    OwlZwpPointerConstraint *constraint = [OwlZwpPointerConstraint
        constraintForSurfaceResource: surfaceResource];
    return constraint != nil && constraint->_active && constraint->_isLock;
}

+ (BOOL) hasActiveConfinementForSurfaceResource:
    (struct wl_resource *) surfaceResource
{
    OwlZwpPointerConstraint *constraint = [OwlZwpPointerConstraint
        constraintForSurfaceResource: surfaceResource];
    return constraint != nil && constraint->_active && !constraint->_isLock;
}

+ (void) warpPointerToSurface: (OwlSurface *) surface
                        point: (NSPoint) point
{
#ifdef OWL_PLATFORM_APPLE
    NSWindow *window = [surface window];
    if (window == nil) {
        return;
    }
    // Surface coordinates (top-left origin) → view (bottom-left) →
    // window base → Cocoa screen → CG global (top-left origin of
    // the primary screen).
    NSPoint viewPoint = NSMakePoint(
        point.x,
        [surface bounds].size.height - point.y
    );
    NSPoint basePoint = [surface convertPoint: viewPoint toView: nil];
    NSPoint screenPoint = [window convertBaseToScreen: basePoint];
    NSScreen *primary = [[NSScreen screens] objectAtIndex: 0];
    CGPoint cgPoint = CGPointMake(
        screenPoint.x,
        NSMaxY([primary frame]) - screenPoint.y
    );
    CGWarpMouseCursorPosition(cgPoint);
    // By default the system suppresses local hardware events for a
    // fraction of a second after a warp, which would make confined
    // pointers feel like they hit glue; turn that off.
    CGSetLocalEventsSuppressionInterval(0.0);
#endif
}

static void constraints_subscribe(void) {
    static BOOL subscribed;
    if (subscribed) {
        return;
    }
    subscribed = YES;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver: [OwlZwpPointerConstraintsV1 class]
               selector: @selector(windowBecameKey:)
                   name: NSWindowDidBecomeKeyNotification
                 object: nil];
    [center addObserver: [OwlZwpPointerConstraintsV1 class]
               selector: @selector(windowResignedKey:)
                   name: NSWindowDidResignKeyNotification
                 object: nil];
}

+ (void) windowBecameKey: (NSNotification *) notification {
    NSWindow *window = [notification object];
    for (OwlZwpPointerConstraint *constraint in constraints) {
        OwlSurface *surface = [constraint surface];
        if (surface != nil && [surface window] == window) {
            [constraint activate];
        }
    }
}

+ (void) windowResignedKey: (NSNotification *) notification {
    NSWindow *window = [notification object];
    for (OwlZwpPointerConstraint *constraint in constraints) {
        OwlSurface *surface = [constraint surface];
        if (surface != nil && [surface window] == window) {
            [constraint deactivate];
        }
    }
}

static void constraints_destroy(struct wl_resource *resource) {
    OwlZwpPointerConstraintsV1 *self = wl_resource_get_user_data(resource);
    [self release];
}

static void constraints_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void constraints_create_constraint(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    struct wl_resource *surface_resource,
    uint32_t lifetime,
    BOOL isLock
) {
    OwlZwpPointerConstraint *existing = [OwlZwpPointerConstraint
        constraintForSurfaceResource: surface_resource];
    // NULL rather than nil: GCC's ObjC headers define nil as (id)0,
    // which fails to parse in functions whose id parameter shadows
    // the id type, like this wayland request handler.
    if (existing != NULL) {
        wl_resource_post_error(
            resource,
            ZWP_POINTER_CONSTRAINTS_V1_ERROR_ALREADY_CONSTRAINED,
            "wl_surface@%u already has a pointer constraint",
            wl_resource_get_id(surface_resource)
        );
        return;
    }

    struct wl_resource *constraint_resource = wl_resource_create(
        client,
        isLock ? &zwp_locked_pointer_v1_interface
               : &zwp_confined_pointer_v1_interface,
        wl_resource_get_version(resource),
        id
    );
    OwlZwpPointerConstraint *constraint = [OwlZwpPointerConstraint alloc];
    constraint = [constraint initWithResource: constraint_resource
                              surfaceResource: surface_resource
                                       isLock: isLock
                                     lifetime: lifetime];

    OwlSurface *surface = wl_resource_get_user_data(surface_resource);
    if ([[surface window] isKeyWindow]) {
        [constraint activate];
    }
    [constraint release];
}

static void constraints_lock_pointer_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    struct wl_resource *surface_resource,
    struct wl_resource *pointer_resource,
    struct wl_resource *region_resource,
    uint32_t lifetime
) {
    constraints_create_constraint(
        client, resource, id, surface_resource, lifetime, YES
    );
}

static void constraints_confine_pointer_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    struct wl_resource *surface_resource,
    struct wl_resource *pointer_resource,
    struct wl_resource *region_resource,
    uint32_t lifetime
) {
    constraints_create_constraint(
        client, resource, id, surface_resource, lifetime, NO
    );
}

static const struct zwp_pointer_constraints_v1_interface constraints_impl = {
    .destroy = constraints_destroy_handler,
    .lock_pointer = constraints_lock_pointer_handler,
    .confine_pointer = constraints_confine_pointer_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &constraints_impl,
        [self retain],
        constraints_destroy
    );
    return self;
}

static void constraints_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &zwp_pointer_constraints_v1_interface,
        version,
        id
    );
    OwlZwpPointerConstraintsV1 *self = [OwlZwpPointerConstraintsV1 alloc];
    [[self initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    constraints_subscribe();
    wl_global_create(
        display,
        &zwp_pointer_constraints_v1_interface,
        1,
        NULL,
        constraints_bind
    );
}

@end
