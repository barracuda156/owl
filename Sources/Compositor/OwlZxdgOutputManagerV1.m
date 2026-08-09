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

#import "OwlZxdgOutputManagerV1.h"
#import "OwlZxdgOutputV1.h"
#import "OwlOutput.h"
#import "xdg-output-unstable-v1.h"


@implementation OwlZxdgOutputManagerV1

static void xdg_output_manager_destroy(struct wl_resource *resource) {
    OwlZxdgOutputManagerV1 *self = wl_resource_get_user_data(resource);
    [self release];
}

static void xdg_output_manager_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void xdg_output_manager_get_xdg_output_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    struct wl_resource *output_resource
) {
    struct wl_resource *xdg_output_resource = wl_resource_create(
        client,
        &zxdg_output_v1_interface,
        wl_resource_get_version(resource),
        id
    );
    OwlOutput *output = wl_resource_get_user_data(output_resource);
    [[[OwlZxdgOutputV1 alloc] initWithResource: xdg_output_resource
                                          output: output
                                  outputResource: output_resource] release];
}

static const struct zxdg_output_manager_v1_interface xdg_output_manager_impl = {
    .destroy = xdg_output_manager_destroy_handler,
    .get_xdg_output = xdg_output_manager_get_xdg_output_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &xdg_output_manager_impl,
        [self retain],
        xdg_output_manager_destroy
    );
    return self;
}

static void xdg_output_manager_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &zxdg_output_manager_v1_interface,
        version,
        id
    );
    [[[OwlZxdgOutputManagerV1 alloc] initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    wl_global_create(
        display,
        &zxdg_output_manager_v1_interface,
        3,
        NULL,
        xdg_output_manager_bind
    );
}

@end
