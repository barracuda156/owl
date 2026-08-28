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

#import "OwlZxdgOutputV1.h"
#import "OwlOutput.h"
#import "xdg-output-unstable-v1.h"


@implementation OwlZxdgOutputV1

// Every live xdg_output, unretained; appended at construction,
// removed in xdg_output_destroy.
static NSMutableArray *xdgOutputs;

+ (void) initialize {
    if (xdgOutputs == nil) {
        xdgOutputs = [[NSMutableArray alloc] initWithCapacity: 1];
    }
}

// Fired when the wl_output resource an xdg_output was paired with
// dies out from under it (client unbound that wl_output, or its
// global was torn down, while still holding this xdg_output). data
// is the output resource, not useful for finding self; recover it
// the same way OwlXdgToplevel recovers self for its set_parent
// destroy listener -- scan the live instances for whose
// _outputResourceDestroyListener this is.
static void xdg_output_output_resource_destroy_notify(
    struct wl_listener *listener,
    void *data
) {
    OwlZxdgOutputV1 *self = nil;
    for (OwlZxdgOutputV1 *xdgOutput in xdgOutputs) {
        if (&xdgOutput->_outputResourceDestroyListener == listener) {
            self = xdgOutput;
            break;
        }
    }
    if (self == nil) {
        return;
    }
    self->_outputResource = NULL;
    wl_list_remove(&self->_outputResourceDestroyListener.link);
    wl_list_init(&self->_outputResourceDestroyListener.link);
}

static void xdg_output_destroy(struct wl_resource *resource) {
    OwlZxdgOutputV1 *self = wl_resource_get_user_data(resource);
    if (self->_outputResource != NULL) {
        wl_list_remove(&self->_outputResourceDestroyListener.link);
    }
    [xdgOutputs removeObjectIdenticalTo: self];
    [self release];
}

static void xdg_output_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static const struct zxdg_output_v1_interface xdg_output_impl = {
    .destroy = xdg_output_destroy_handler
};

// Sends the logical position/size for frame, then the terminating
// done event, applying the same wl_output.done-vs-zxdg_output_v1.done
// fallback used at construction time.
- (void) sendLogicalGeometryForFrame: (NSRect) frame {
    zxdg_output_v1_send_logical_position(
        _resource,
        (int32_t)frame.origin.x,
        (int32_t)frame.origin.y
    );
    zxdg_output_v1_send_logical_size(
        _resource,
        (int32_t)frame.size.width,
        (int32_t)frame.size.height
    );

    // Deprecated since v3: compositors must send wl_output.done on
    // the corresponding wl_output instead of zxdg_output_v1.done.
    // But that only works if the client actually bound wl_output at
    // a version that has .done (added in v2); a client can legally
    // request zxdg_output_manager_v1 at v3 while still holding an
    // older wl_output, so fall back to the object's own done event
    // whenever the wl_output target can't take the event -- including
    // when it has already died (see the destroy listener above).
    if (wl_resource_get_version(_resource) >= 3
        && _outputResource != NULL
        && wl_resource_get_version(_outputResource) >= WL_OUTPUT_DONE_SINCE_VERSION) {
        wl_output_send_done(_outputResource);
    } else {
        zxdg_output_v1_send_done(_resource);
    }
}

- (void) refresh {
    NSScreen *screen = [OwlOutput screenForDisplayID: _displayID];
    if (screen == nil) {
        return;
    }
    [self sendLogicalGeometryForFrame: [screen frame]];
}

+ (void) refreshDisplayID: (uint32_t) displayID {
    for (OwlZxdgOutputV1 *xdgOutput in xdgOutputs) {
        if (xdgOutput->_displayID == displayID) {
            [xdgOutput refresh];
        }
    }
}

- (id) initWithResource: (struct wl_resource *) resource
                  output: (OwlOutput *) output
          outputResource: (struct wl_resource *) outputResource
{
    _resource = resource;
    _outputResource = outputResource;
    _displayID = [output displayID];
    _outputResourceDestroyListener.notify =
        xdg_output_output_resource_destroy_notify;
    wl_resource_add_destroy_listener(
        outputResource,
        &_outputResourceDestroyListener
    );
    [xdgOutputs addObject: self];

    wl_resource_set_implementation(
        resource,
        &xdg_output_impl,
        [self retain],
        xdg_output_destroy
    );

    // Owl doesn't apply any surface scaling beyond the integer
    // backingScaleFactor wl_output.scale already advertises, so the
    // logical geometry is the same as the physical one reported by
    // wl_output.geometry/mode. name/description are deliberately not
    // duplicated here: they live on wl_output v4, which owl sends.
    // [output screen] can be nil via the same output_bind race noted
    // on OwlOutput's -sendOutputInfo; guard explicitly rather than
    // messaging nil for a struct return.
    NSScreen *screen = [output screen];
    [self sendLogicalGeometryForFrame:
        (screen != nil) ? [screen frame] : NSZeroRect];

    return self;
}

@end
