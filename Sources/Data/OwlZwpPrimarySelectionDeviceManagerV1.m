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

#import "OwlZwpPrimarySelectionDeviceManagerV1.h"
#import "OwlZwpPrimarySelectionSourceV1.h"
#import "OwlZwpPrimarySelectionDeviceV1.h"
#import "primary-selection-unstable-v1.h"


@implementation OwlZwpPrimarySelectionDeviceManagerV1

static void primary_selection_device_manager_destroy(struct wl_resource *resource) {
    OwlZwpPrimarySelectionDeviceManagerV1 *self = wl_resource_get_user_data(resource);
    [self release];
}

static void primary_selection_device_manager_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void primary_selection_device_manager_create_source_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id
) {
    struct wl_resource *source_resource = wl_resource_create(
        client,
        &zwp_primary_selection_source_v1_interface,
        wl_resource_get_version(resource),
        id
    );
    [[[OwlZwpPrimarySelectionSourceV1 alloc]
        initWithResource: source_resource] release];
}

static void primary_selection_device_manager_get_device_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    struct wl_resource *seat_resource
) {
    struct wl_resource *device_resource = wl_resource_create(
        client,
        &zwp_primary_selection_device_v1_interface,
        wl_resource_get_version(resource),
        id
    );
    [[[OwlZwpPrimarySelectionDeviceV1 alloc]
        initWithResource: device_resource] release];
}

static const struct zwp_primary_selection_device_manager_v1_interface
primary_selection_device_manager_impl = {
    .create_source = primary_selection_device_manager_create_source_handler,
    .get_device = primary_selection_device_manager_get_device_handler,
    .destroy = primary_selection_device_manager_destroy_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &primary_selection_device_manager_impl,
        [self retain],
        primary_selection_device_manager_destroy
    );
    return self;
}

static void primary_selection_device_manager_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &zwp_primary_selection_device_manager_v1_interface,
        version,
        id
    );
    [[[OwlZwpPrimarySelectionDeviceManagerV1 alloc]
        initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    wl_global_create(
        display,
        &zwp_primary_selection_device_manager_v1_interface,
        1,
        NULL,
        primary_selection_device_manager_bind
    );
}

@end
