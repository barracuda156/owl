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

#import "OwlExtIdleNotifierV1.h"
#import "OwlZwpIdleInhibitManagerV1.h"
#import "OwlServer.h"
#import "OwlFeatures.h"
#import "ext-idle-notify-v1.h"

#ifdef OWL_PLATFORM_APPLE
    #import <ApplicationServices/ApplicationServices.h>
#endif


// Milliseconds since the last hardware input event anywhere in the
// session, or -1 where no such clock exists (GNUstep): then idle is
// never detected and notifications stay quiet.
static int64_t idle_elapsed_ms(void) {
#ifdef OWL_PLATFORM_APPLE
    CFTimeInterval seconds = CGEventSourceSecondsSinceLastEventType(
        kCGEventSourceStateCombinedSessionState,
        kCGAnyInputEventType
    );
    return (int64_t) (seconds * 1000.0);
#else
    return -1;
#endif
}

/* One ext_idle_notification_v1. */
@interface OwlExtIdleNotification : NSObject {
@public
    struct wl_resource *_resource;
    uint32_t _timeoutMs;
    BOOL _obeysInhibitors;
    BOOL _idled;
    // What the idle clock read at the previous check; the clock
    // running backwards between two checks is how input activity is
    // detected, since comparing against the timeout alone can never
    // notice activity for timeouts shorter than the poll interval
    // (including the explicitly-valid zero timeout).
    int64_t _lastElapsedMs;
    NSTimer *_timer;
}

- (id) initWithResource: (struct wl_resource *) resource
              timeoutMs: (uint32_t) timeoutMs
        obeysInhibitors: (BOOL) obeysInhibitors;

@end

@implementation OwlExtIdleNotification

static NSMutableArray *notifications;

+ (void) initialize {
    if (notifications == nil) {
        notifications = [[NSMutableArray alloc] initWithCapacity: 1];
    }
}

- (void) scheduleCheckAfterMs: (int64_t) delayMs {
    [_timer invalidate];
    [_timer release];
    // Clamp so that an already-expired deadline still takes a trip
    // through the run loop rather than looping on the spot.
    if (delayMs < 50) {
        delayMs = 50;
    }
    _timer = [[NSTimer scheduledTimerWithTimeInterval: delayMs / 1000.0
                                               target: self
                                             selector: @selector(check:)
                                             userInfo: nil
                                              repeats: NO] retain];
}

- (void) check: (NSTimer *) timer {
    int64_t elapsed = idle_elapsed_ms();
    if (elapsed < 0) {
        // No idle clock on this platform; never idle, never poll.
        return;
    }
    // The idle clock going backwards means input arrived since the
    // previous check, even when it never dipped below the timeout
    // between two polls.
    BOOL sawActivity = elapsed < _lastElapsedMs;
    _lastElapsedMs = elapsed;
    BOOL inhibited = _obeysInhibitors
        && [OwlZwpIdleInhibitManagerV1 anyInhibitorsHeld];

    if (!_idled) {
        if (!inhibited && elapsed >= (int64_t) _timeoutMs) {
            _idled = YES;
            ext_idle_notification_v1_send_idled(_resource);
            [[OwlServer sharedServer] flushClientsLater];
            // Poll for the resume: there is no push notification
            // for "input happened somewhere in the session".
            [self scheduleCheckAfterMs: 1000];
        } else if (inhibited) {
            // While inhibited the countdown effectively restarts.
            [self scheduleCheckAfterMs: _timeoutMs];
        } else {
            [self scheduleCheckAfterMs: (int64_t) _timeoutMs - elapsed];
        }
    } else {
        if (inhibited || sawActivity || elapsed < (int64_t) _timeoutMs) {
            _idled = NO;
            ext_idle_notification_v1_send_resumed(_resource);
            [[OwlServer sharedServer] flushClientsLater];
            [self scheduleCheckAfterMs:
                      inhibited ? (int64_t) _timeoutMs
                                : (int64_t) _timeoutMs - elapsed];
        } else {
            [self scheduleCheckAfterMs: 1000];
        }
    }
}

static void idle_notification_destroy(struct wl_resource *resource) {
    OwlExtIdleNotification *self = wl_resource_get_user_data(resource);
    // The timer retains its target; break that before letting go.
    [self->_timer invalidate];
    [self->_timer release];
    self->_timer = nil;
    [notifications removeObjectIdenticalTo: self];
    [self release];
}

static void idle_notification_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static const struct ext_idle_notification_v1_interface
idle_notification_impl = {
    .destroy = idle_notification_destroy_handler
};

- (id) initWithResource: (struct wl_resource *) resource
              timeoutMs: (uint32_t) timeoutMs
        obeysInhibitors: (BOOL) obeysInhibitors
{
    _resource = resource;
    _timeoutMs = timeoutMs;
    _obeysInhibitors = obeysInhibitors;
    [notifications addObject: self];

    wl_resource_set_implementation(
        resource,
        &idle_notification_impl,
        [self retain],
        idle_notification_destroy
    );

    // Take stock right away: the seat may already be idle for
    // longer than the requested timeout.
    [self scheduleCheckAfterMs: 0];

    return self;
}

@end


@implementation OwlExtIdleNotifierV1

static void idle_notifier_destroy(struct wl_resource *resource) {
    OwlExtIdleNotifierV1 *self = wl_resource_get_user_data(resource);
    [self release];
}

static void idle_notifier_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void idle_notifier_get_notification(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    uint32_t timeout,
    BOOL obeysInhibitors
) {
    struct wl_resource *notification_resource = wl_resource_create(
        client,
        &ext_idle_notification_v1_interface,
        wl_resource_get_version(resource),
        id
    );
    OwlExtIdleNotification *notification = [OwlExtIdleNotification alloc];
    [[notification initWithResource: notification_resource
                          timeoutMs: timeout
                    obeysInhibitors: obeysInhibitors] release];
}

static void idle_notifier_get_idle_notification_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    uint32_t timeout,
    struct wl_resource *seat_resource
) {
    idle_notifier_get_notification(client, resource, id, timeout, YES);
}

static void idle_notifier_get_input_idle_notification_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    uint32_t timeout,
    struct wl_resource *seat_resource
) {
    idle_notifier_get_notification(client, resource, id, timeout, NO);
}

static const struct ext_idle_notifier_v1_interface idle_notifier_impl = {
    .destroy = idle_notifier_destroy_handler,
    .get_idle_notification = idle_notifier_get_idle_notification_handler,
    .get_input_idle_notification =
        idle_notifier_get_input_idle_notification_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &idle_notifier_impl,
        [self retain],
        idle_notifier_destroy
    );
    return self;
}

static void idle_notifier_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &ext_idle_notifier_v1_interface,
        version,
        id
    );
    [[[OwlExtIdleNotifierV1 alloc] initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    wl_global_create(
        display,
        &ext_idle_notifier_v1_interface,
        2,
        NULL,
        idle_notifier_bind
    );
}

@end
