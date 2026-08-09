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

static void xdg_output_destroy(struct wl_resource *resource) {
    OwlZxdgOutputV1 *self = wl_resource_get_user_data(resource);
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

- (id) initWithResource: (struct wl_resource *) resource
                  output: (OwlOutput *) output
          outputResource: (struct wl_resource *) outputResource
{
    _resource = resource;
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
    NSRect frame = [[output screen] frame];
    zxdg_output_v1_send_logical_position(
        resource,
        (int32_t)frame.origin.x,
        (int32_t)frame.origin.y
    );
    zxdg_output_v1_send_logical_size(
        resource,
        (int32_t)frame.size.width,
        (int32_t)frame.size.height
    );

    // Deprecated since v3: compositors must send wl_output.done on
    // the corresponding wl_output instead of zxdg_output_v1.done.
    // But that only works if the client actually bound wl_output at
    // a version that has .done (added in v2); a client can legally
    // request zxdg_output_manager_v1 at v3 while still holding an
    // older wl_output, so fall back to the object's own done event
    // whenever the wl_output target can't take the event.
    if (wl_resource_get_version(resource) >= 3
        && wl_resource_get_version(outputResource) >= WL_OUTPUT_DONE_SINCE_VERSION) {
        wl_output_send_done(outputResource);
    } else {
        zxdg_output_v1_send_done(resource);
    }

    return self;
}

@end
