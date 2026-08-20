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

#import "OwlXdgSystemBellV1.h"
#import "xdg-system-bell-v1.h"


@implementation OwlXdgSystemBellV1

static void system_bell_destroy(struct wl_resource *resource) {
    OwlXdgSystemBellV1 *self = wl_resource_get_user_data(resource);
    [self release];
}

static void system_bell_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void system_bell_ring_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *surface_resource
) {
    // The optional surface tells the compositor which window rang,
    // for attention badges and the like; the system beep is global,
    // so it goes unused.
    NSBeep();
}

static const struct xdg_system_bell_v1_interface system_bell_impl = {
    .destroy = system_bell_destroy_handler,
    .ring = system_bell_ring_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &system_bell_impl,
        [self retain],
        system_bell_destroy
    );
    return self;
}

static void system_bell_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &xdg_system_bell_v1_interface,
        version,
        id
    );
    [[[OwlXdgSystemBellV1 alloc] initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    wl_global_create(
        display,
        &xdg_system_bell_v1_interface,
        1,
        NULL,
        system_bell_bind
    );
}

@end
