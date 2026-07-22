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

#import "OwlSeat.h"
#import "OwlPointer.h"
#import "OwlKeyboard.h"
#import <wayland-server.h>

@implementation OwlSeat

static void seat_get_pointer(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id
) {
    uint32_t version = wl_resource_get_version(resource);
    struct wl_resource *pointer_resource = wl_resource_create(
        client,
        &wl_pointer_interface,
        version,
        id
    );
    [[[OwlPointer alloc] initWithResource: pointer_resource] release];
}

static void seat_get_keyboard(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id
) {
    uint32_t version = wl_resource_get_version(resource);
    struct wl_resource *keyboard_resource = wl_resource_create(
        client,
        &wl_keyboard_interface,
        version,
        id
    );
    [[[OwlKeyboard alloc] initWithResource: keyboard_resource] release];
}

static void touch_release_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static const struct wl_touch_interface touch_impl = {
    .release = touch_release_handler
};

static void seat_get_touch(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id
) {
    // We never advertise the touch capability, so a well-behaved
    // client will not request a touch object; still, don't crash
    // if one does. Give it an inert wl_touch.
    uint32_t version = wl_resource_get_version(resource);
    struct wl_resource *touch_resource = wl_resource_create(
        client,
        &wl_touch_interface,
        version,
        id
    );
    wl_resource_set_implementation(touch_resource, &touch_impl, NULL, NULL);
}

static void seat_release_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static const struct wl_seat_interface seat_impl = {
    .get_pointer = seat_get_pointer,
    .get_keyboard = seat_get_keyboard,
    .get_touch = seat_get_touch,
    .release = seat_release_handler
};

static void seat_destroy(struct wl_resource *resource) {
    OwlSeat *self = wl_resource_get_user_data(resource);
    [self release];
}

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;

    wl_resource_set_implementation(
        resource,
        &seat_impl,
        [self retain],
        seat_destroy
    );

    wl_seat_send_capabilities(
        resource,
        WL_SEAT_CAPABILITY_POINTER | WL_SEAT_CAPABILITY_KEYBOARD
    );

    if (wl_resource_get_version(resource) >= 2) {
        wl_seat_send_name(resource, "seat0");
    }

    return self;
}

static void seat_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &wl_seat_interface,
        version,
        id
    );
    [[[OwlSeat alloc] initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    // Version 5 is required by clients like foot; it obligates
    // us to send wl_pointer.frame events and keyboard repeat
    // information, which OwlPointer and OwlKeyboard handle.
    wl_global_create(display, &wl_seat_interface, 5, NULL, seat_bind);
}

@end
