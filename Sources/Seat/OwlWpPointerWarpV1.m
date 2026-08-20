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

#import "OwlWpPointerWarpV1.h"
#import "OwlSurface.h"
#import "OwlPointer.h"
#import "OwlZwpPointerConstraintsV1.h"
#import "OwlServer.h"
#import "pointer-warp-v1.h"


@implementation OwlWpPointerWarpV1

static void pointer_warp_destroy(struct wl_resource *resource) {
    OwlWpPointerWarpV1 *self = wl_resource_get_user_data(resource);
    [self release];
}

static void pointer_warp_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void pointer_warp_warp_pointer_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *surface_resource,
    struct wl_resource *pointer_resource,
    wl_fixed_t x,
    wl_fixed_t y,
    uint32_t serial
) {
    OwlSurface *surface = wl_resource_get_user_data(surface_resource);
    // The compositor is free to ignore a warp; do so unless the
    // surface actually holds the pointer focus. (The serial goes
    // unvalidated: owl does not keep a serial history.)
    if (![surface mouseIsInside]) {
        return;
    }
    // Also ignore warps while the pointer is locked to the surface:
    // moving the pinned cursor would fight the lock, and sending
    // the absolute motion below is forbidden while locked. The spec
    // itself notes warping is no substitute for locking.
    if ([OwlZwpPointerConstraintsV1
            hasActiveLockForSurfaceResource: surface_resource]) {
        return;
    }

    NSPoint point = NSMakePoint(wl_fixed_to_double(x), wl_fixed_to_double(y));
    // Ignore warps to outside the surface, with the same 1px margin
    // of tolerance Hyprland allows.
    NSSize size = [surface bounds].size;
    if (point.x < -1.0 || point.y < -1.0
        || point.x > size.width + 1.0 || point.y > size.height + 1.0) {
        return;
    }

    [OwlZwpPointerConstraintsV1 warpPointerToSurface: surface
                                               point: point];
    // Let the client know where its pointer ended up right away.
    [[surface pointer] sendMotionAtPoint: point];
    [[OwlServer sharedServer] flushClientsLater];
}

static const struct wp_pointer_warp_v1_interface pointer_warp_impl = {
    .destroy = pointer_warp_destroy_handler,
    .warp_pointer = pointer_warp_warp_pointer_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &pointer_warp_impl,
        [self retain],
        pointer_warp_destroy
    );
    return self;
}

static void pointer_warp_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &wp_pointer_warp_v1_interface,
        version,
        id
    );
    [[[OwlWpPointerWarpV1 alloc] initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    wl_global_create(
        display,
        &wp_pointer_warp_v1_interface,
        1,
        NULL,
        pointer_warp_bind
    );
}

@end
