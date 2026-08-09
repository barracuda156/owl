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

#import "OwlZwpIdleInhibitManagerV1.h"
#import "idle-inhibit-unstable-v1.h"
#import "OwlFeatures.h"

#ifdef OWL_HAS_IOPM
#import <IOKit/pwr_mgt/IOPMLib.h>
#elif defined(OWL_PLATFORM_APPLE)
#import <CoreServices/CoreServices.h>
#endif


/* Tracks one live zwp_idle_inhibitor_v1, keyed to the wl_surface it
 * was created for (only for destroy-listener bookkeeping symmetry
 * with OwlWpContentType; unlike content-type, a surface may have any
 * number of inhibitors, so there's no duplicate check here). */
@interface OwlZwpIdleInhibitor : NSObject {
@public
    struct wl_resource *_resource;
    struct wl_resource *_surfaceResource;
    struct wl_listener _surfaceDestroyListener;
}

- (id) initWithResource: (struct wl_resource *) resource
         surfaceResource: (struct wl_resource *) surfaceResource;

@end

@implementation OwlZwpIdleInhibitor

static NSMutableArray *inhibitors;

+ (void) initialize {
    if (inhibitors == nil) {
        inhibitors = [[NSMutableArray alloc] initWithCapacity: 1];
    }
}

#ifdef OWL_HAS_IOPM
static IOPMAssertionID powerAssertionID;
static BOOL powerAssertionHeld;
#elif defined(OWL_PLATFORM_APPLE)
static NSTimer *activityTimer;
#endif

#if defined(OWL_PLATFORM_APPLE) && !defined(OWL_HAS_IOPM)
+ (void) keepSystemActiveTimer: (NSTimer *) timer {
    UpdateSystemActivity(OverallAct);
}
#endif

// Called when the first inhibitor is created / the last one goes
// away. Owl doesn't track per-surface visibility, so this simply
// treats "at least one live inhibitor" as "inhibit idling", per the
// spec's "counting mapped inhibitors is close enough for v1" note.
static void acquirePowerAssertion(void) {
#ifdef OWL_HAS_IOPM
    if (powerAssertionHeld) {
        return;
    }
    // kIOPMAssertionTypeNoDisplaySleep is the 10.6+ spelling; the
    // newer kIOPMAssertionTypePreventUserIdleDisplaySleep alias
    // only exists since 10.7 and fails to build against the 10.6
    // SDK. The old name is deprecated (not removed) on 10.7+, so
    // it's fine to use unconditionally here.
    IOReturn ret = IOPMAssertionCreateWithName(
        kIOPMAssertionTypeNoDisplaySleep,
        kIOPMAssertionLevelOn,
        CFSTR("Owl: a client is inhibiting idle"),
        &powerAssertionID
    );
    powerAssertionHeld = (ret == kIOReturnSuccess);
#elif defined(OWL_PLATFORM_APPLE)
    if (activityTimer != nil) {
        return;
    }
    // No IOPMAssertion API on 10.5; fall back to periodically
    // resetting the idle timer. 15s comfortably beats any real
    // idle/screensaver timeout.
    activityTimer = [[NSTimer scheduledTimerWithTimeInterval: 15.0
                                                        target: [OwlZwpIdleInhibitor class]
                                                      selector: @selector(keepSystemActiveTimer:)
                                                      userInfo: nil
                                                       repeats: YES] retain];
    UpdateSystemActivity(OverallAct);
#endif
}

static void releasePowerAssertion(void) {
#ifdef OWL_HAS_IOPM
    if (!powerAssertionHeld) {
        return;
    }
    IOPMAssertionRelease(powerAssertionID);
    powerAssertionHeld = NO;
#elif defined(OWL_PLATFORM_APPLE)
    [activityTimer invalidate];
    [activityTimer release];
    activityTimer = nil;
#endif
}

static void surface_destroy_notify(struct wl_listener *listener, void *data) {
    OwlZwpIdleInhibitor *self = nil;
    for (OwlZwpIdleInhibitor *inhibitor in inhibitors) {
        if (&inhibitor->_surfaceDestroyListener == listener) {
            self = inhibitor;
            break;
        }
    }
    if (self == nil) {
        return;
    }

    self->_surfaceResource = NULL;
    wl_list_remove(&self->_surfaceDestroyListener.link);
    wl_list_init(&self->_surfaceDestroyListener.link);
}

static void idle_inhibitor_destroy(struct wl_resource *resource) {
    OwlZwpIdleInhibitor *self = wl_resource_get_user_data(resource);
    [inhibitors removeObjectIdenticalTo: self];
    if ([inhibitors count] == 0) {
        releasePowerAssertion();
    }
    [self release];
}

static void idle_inhibitor_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static const struct zwp_idle_inhibitor_v1_interface idle_inhibitor_impl = {
    .destroy = idle_inhibitor_destroy_handler
};

- (id) initWithResource: (struct wl_resource *) resource
         surfaceResource: (struct wl_resource *) surfaceResource
{
    _resource = resource;
    _surfaceResource = surfaceResource;
    _surfaceDestroyListener.notify = surface_destroy_notify;
    wl_resource_add_destroy_listener(
        surfaceResource,
        &_surfaceDestroyListener
    );
    [inhibitors addObject: self];
    acquirePowerAssertion();

    wl_resource_set_implementation(
        resource,
        &idle_inhibitor_impl,
        [self retain],
        idle_inhibitor_destroy
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


@implementation OwlZwpIdleInhibitManagerV1

static void idle_inhibit_manager_destroy(struct wl_resource *resource) {
    OwlZwpIdleInhibitManagerV1 *self = wl_resource_get_user_data(resource);
    [self release];
}

static void idle_inhibit_manager_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void idle_inhibit_manager_create_inhibitor_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    struct wl_resource *surface_resource
) {
    struct wl_resource *inhibitor_resource = wl_resource_create(
        client,
        &zwp_idle_inhibitor_v1_interface,
        wl_resource_get_version(resource),
        id
    );
    OwlZwpIdleInhibitor *inhibitor = [OwlZwpIdleInhibitor alloc];
    [[inhibitor initWithResource: inhibitor_resource
                  surfaceResource: surface_resource] release];
}

static const struct zwp_idle_inhibit_manager_v1_interface
idle_inhibit_manager_impl = {
    .destroy = idle_inhibit_manager_destroy_handler,
    .create_inhibitor = idle_inhibit_manager_create_inhibitor_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &idle_inhibit_manager_impl,
        [self retain],
        idle_inhibit_manager_destroy
    );
    return self;
}

static void idle_inhibit_manager_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &zwp_idle_inhibit_manager_v1_interface,
        version,
        id
    );
    [[[OwlZwpIdleInhibitManagerV1 alloc] initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    wl_global_create(
        display,
        &zwp_idle_inhibit_manager_v1_interface,
        1,
        NULL,
        idle_inhibit_manager_bind
    );
}

@end
