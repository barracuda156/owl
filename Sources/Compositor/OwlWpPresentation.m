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

#import "OwlWpPresentation.h"
#import "OwlSurface.h"
#import "presentation-time.h"
#import <wayland-server.h>
#import <time.h>
#ifndef CLOCK_MONOTONIC
#import <sys/time.h>
#endif


// The clock we declare in wp_presentation.clock_id and sample for
// the presented event. Prefer CLOCK_MONOTONIC where the system has
// clock_gettime (Mac OS X gained it in 10.12; MacPorts
// legacy-support provides it on older systems); otherwise fall back
// to gettimeofday, which samples CLOCK_REALTIME (0 on both Darwin
// and Linux).
#ifdef CLOCK_MONOTONIC
#define OWL_PRESENTATION_CLOCK CLOCK_MONOTONIC
#else
#define OWL_PRESENTATION_CLOCK 0
#endif

static void presentation_clock_now(uint64_t *sec, uint32_t *nsec) {
#ifdef CLOCK_MONOTONIC
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    *sec = (uint64_t) ts.tv_sec;
    *nsec = (uint32_t) ts.tv_nsec;
#else
    struct timeval tv;
    gettimeofday(&tv, NULL);
    *sec = (uint64_t) tv.tv_sec;
    *nsec = (uint32_t) tv.tv_usec * 1000;
#endif
}


@implementation OwlWpPresentationFeedback

static void presentation_feedback_destroy(struct wl_resource *resource) {
    OwlWpPresentationFeedback *self = wl_resource_get_user_data(resource);
    // The resource can be destroyed before the surface gets around
    // to presenting or discarding (e.g. on client disconnect); null
    // it out so the send methods know to do nothing.
    self->_resource = NULL;
    [self release];
}

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    // Like wl_callback, wp_presentation_feedback has no requests.
    wl_resource_set_implementation(
        resource,
        NULL,
        [self retain],
        presentation_feedback_destroy
    );
    return self;
}

- (void) sendPresented {
    if (_resource == NULL) {
        return;
    }
    uint64_t sec;
    uint32_t nsec;
    presentation_clock_now(&sec, &nsec);
    wp_presentation_feedback_send_presented(
        _resource,
        (uint32_t) (sec >> 32),
        (uint32_t) sec,
        nsec,
        0, /* refresh: cannot be usefully predicted */
        0, /* seq_hi: no retrace counter */
        0, /* seq_lo */
        0  /* flags: none of the kind guarantees apply */
    );
    // presented is a destructor event.
    wl_resource_destroy(_resource);
}

- (void) sendDiscarded {
    if (_resource == NULL) {
        return;
    }
    wp_presentation_feedback_send_discarded(_resource);
    // discarded is a destructor event.
    wl_resource_destroy(_resource);
}

@end


@implementation OwlWpPresentation

static void presentation_destroy(struct wl_resource *resource) {
    OwlWpPresentation *self = wl_resource_get_user_data(resource);
    [self release];
}

static void presentation_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void presentation_feedback_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *surface_resource,
    uint32_t id
) {
    OwlSurface *surface = wl_resource_get_user_data(surface_resource);
    struct wl_resource *feedback_resource = wl_resource_create(
        client,
        &wp_presentation_feedback_interface,
        wl_resource_get_version(resource),
        id
    );
    OwlWpPresentationFeedback *feedback = [OwlWpPresentationFeedback alloc];
    feedback = [feedback initWithResource: feedback_resource];
    [surface addPresentationFeedback: feedback];
    [feedback release];
}

static const struct wp_presentation_interface presentation_impl = {
    .destroy = presentation_destroy_handler,
    .feedback = presentation_feedback_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &presentation_impl,
        [self retain],
        presentation_destroy
    );

    wp_presentation_send_clock_id(resource, (uint32_t) OWL_PRESENTATION_CLOCK);

    return self;
}

static void presentation_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &wp_presentation_interface,
        version,
        id
    );
    [[[OwlWpPresentation alloc] initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    wl_global_create(
        display,
        &wp_presentation_interface,
        1,
        NULL,
        presentation_bind
    );
}

@end
