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

#import "OwlZwlrGammaControlManagerV1.h"
#import "OwlOutput.h"
#import "OwlFeatures.h"
#import "wlr-gamma-control-unstable-v1.h"

#include <errno.h>
#include <unistd.h>
#include <stdlib.h>

#ifdef OWL_PLATFORM_APPLE
    #import <ApplicationServices/ApplicationServices.h>
#endif


/* One zwlr_gamma_control_v1. _gammaSize is 0 for an inert control
 * (either the platform can't adjust gamma at all, or another client
 * already controls this display); everything past creation is a
 * no-op for an inert control. */
@interface OwlZwlrGammaControlV1 : NSObject {
@public
    struct wl_resource *_resource;
    uint32_t _displayID;
    uint32_t _gammaSize;
}

- (id) initWithResource: (struct wl_resource *) resource
          outputResource: (struct wl_resource *) outputResource;

@end

@implementation OwlZwlrGammaControlV1

// Displays that currently have a live (non-inert) gamma control,
// one at most per display id, per spec ("exclusive access").
static NSMutableArray *liveControls;

+ (void) initialize {
    if (liveControls == nil) {
        liveControls = [[NSMutableArray alloc] initWithCapacity: 1];
    }
}

#ifdef OWL_PLATFORM_APPLE
static BOOL displayIDForOutputResource(
    struct wl_resource *outputResource,
    uint32_t *outDisplayID
) {
    OwlOutput *output = wl_resource_get_user_data(outputResource);
    NSScreen *screen = [output screen];
    NSNumber *number = [[screen deviceDescription]
        objectForKey: @"NSScreenNumber"];
    if (number == nil) {
        return NO;
    }
    *outDisplayID = [number unsignedIntValue];
    return YES;
}
#endif

static void gamma_control_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void gamma_control_set_gamma_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    int32_t fd
) {
    OwlZwlrGammaControlV1 *self = wl_resource_get_user_data(resource);

    if (self->_gammaSize == 0) {
        // Inert control (unsupported platform, or lost the race for
        // exclusive access to this display); nothing to apply.
        close(fd);
        return;
    }

#ifdef OWL_PLATFORM_APPLE
    // Guard against the (theoretical, since gammaSize comes from CG,
    // not the client) multiplication overflowing size_t.
    size_t maxSize = ((size_t) -1) / (3 * sizeof(uint16_t));
    if (self->_gammaSize > maxSize) {
        close(fd);
        wl_resource_post_error(
            resource,
            ZWLR_GAMMA_CONTROL_V1_ERROR_INVALID_GAMMA,
            "gamma size too large"
        );
        return;
    }

    size_t expected = (size_t) self->_gammaSize * 3 * sizeof(uint16_t);
    uint16_t *buf = malloc(expected);
    if (buf == NULL) {
        close(fd);
        return;
    }

    size_t total = 0;
    BOOL ok = YES;
    while (total < expected) {
        ssize_t n = read(fd, (char *) buf + total, expected - total);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            ok = NO;
            break;
        }
        if (n == 0) {
            // Short read: client sent fewer bytes than gamma_size
            // promised.
            ok = NO;
            break;
        }
        total += (size_t) n;
    }
    close(fd);

    if (!ok || total != expected) {
        free(buf);
        wl_resource_post_error(
            resource,
            ZWLR_GAMMA_CONTROL_V1_ERROR_INVALID_GAMMA,
            "gamma table has the wrong size"
        );
        return;
    }

    // buf is size red u16s, then green, then blue; table is the same
    // layout as CGGammaValue (float) fractions, so a straight index
    // conversion preserves the channel order.
    CGGammaValue *table = malloc(sizeof(CGGammaValue) * 3 * self->_gammaSize);
    if (table != NULL) {
        uint32_t i;
        for (i = 0; i < 3 * self->_gammaSize; i++) {
            table[i] = (CGGammaValue) buf[i] / 65535.0f;
        }
        CGSetDisplayTransferByTable(
            (CGDirectDisplayID) self->_displayID,
            self->_gammaSize,
            table,
            table + self->_gammaSize,
            table + 2 * self->_gammaSize
        );
        free(table);
    }
    free(buf);
#else
    close(fd);
#endif
}

static const struct zwlr_gamma_control_v1_interface gamma_control_impl = {
    .set_gamma = gamma_control_set_gamma_handler,
    .destroy = gamma_control_destroy_handler
};

static void gamma_control_destroy(struct wl_resource *resource) {
    OwlZwlrGammaControlV1 *self = wl_resource_get_user_data(resource);
    if (self->_gammaSize != 0) {
        [liveControls removeObjectIdenticalTo: self];
#ifdef OWL_PLATFORM_APPLE
        // Global (restores every display's ColorSync gamma), not
        // just this one -- there's no per-display restore API, and
        // this is the only owl controller that ever touches gamma,
        // so restoring everything is harmless and period-correct.
        CGDisplayRestoreColorSyncSettings();
#endif
    }
    [self release];
}

- (id) initWithResource: (struct wl_resource *) resource
          outputResource: (struct wl_resource *) outputResource
{
    _resource = resource;
    _gammaSize = 0;

    wl_resource_set_implementation(
        resource,
        &gamma_control_impl,
        [self retain],
        gamma_control_destroy
    );

#ifdef OWL_PLATFORM_APPLE
    uint32_t displayID;
    if (!displayIDForOutputResource(outputResource, &displayID)) {
        zwlr_gamma_control_v1_send_failed(resource);
        return self;
    }

    for (OwlZwlrGammaControlV1 *existing in liveControls) {
        if (existing->_displayID == displayID) {
            // Another client already has exclusive gamma control
            // for this display -- leave this one inert.
            zwlr_gamma_control_v1_send_failed(resource);
            return self;
        }
    }

    uint32_t size = (uint32_t) CGDisplayGammaTableCapacity(
        (CGDirectDisplayID) displayID);
    if (size == 0) {
        zwlr_gamma_control_v1_send_failed(resource);
        return self;
    }

    _displayID = displayID;
    _gammaSize = size;
    [liveControls addObject: self];
    zwlr_gamma_control_v1_send_gamma_size(resource, _gammaSize);
#else
    // GNUstep: compositor cannot adjust gamma.
    zwlr_gamma_control_v1_send_failed(resource);
#endif

    return self;
}

@end


@implementation OwlZwlrGammaControlManagerV1

static void gamma_control_manager_destroy(struct wl_resource *resource) {
    OwlZwlrGammaControlManagerV1 *self = wl_resource_get_user_data(resource);
    [self release];
}

static void gamma_control_manager_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void gamma_control_manager_get_gamma_control_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id_,
    struct wl_resource *output_resource
) {
    struct wl_resource *control_resource = wl_resource_create(
        client,
        &zwlr_gamma_control_v1_interface,
        wl_resource_get_version(resource),
        id_
    );
    [[[OwlZwlrGammaControlV1 alloc] initWithResource: control_resource
                                       outputResource: output_resource]
        release];
}

static const struct zwlr_gamma_control_manager_v1_interface
gamma_control_manager_impl = {
    .get_gamma_control = gamma_control_manager_get_gamma_control_handler,
    .destroy = gamma_control_manager_destroy_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &gamma_control_manager_impl,
        [self retain],
        gamma_control_manager_destroy
    );
    return self;
}

static void gamma_control_manager_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id_
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &zwlr_gamma_control_manager_v1_interface,
        version,
        id_
    );
    [[[OwlZwlrGammaControlManagerV1 alloc] initWithResource: resource]
        release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    wl_global_create(
        display,
        &zwlr_gamma_control_manager_v1_interface,
        1,
        NULL,
        gamma_control_manager_bind
    );
}

@end
