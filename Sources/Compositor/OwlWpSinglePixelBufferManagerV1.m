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

#import "OwlWpSinglePixelBufferManagerV1.h"
#import "OwlSinglePixelBuffer.h"
#import "single-pixel-buffer-v1.h"
#import <wayland-server.h>


@implementation OwlWpSinglePixelBufferManagerV1

static void single_pixel_buffer_manager_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void single_pixel_buffer_manager_create_u32_rgba_buffer_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    uint32_t r,
    uint32_t g,
    uint32_t b,
    uint32_t a
) {
    struct wl_resource *buffer_resource = wl_resource_create(
        client,
        &wl_buffer_interface,
        1,
        id
    );
    OwlSinglePixelBuffer *buffer = [OwlSinglePixelBuffer alloc];
    [[buffer initWithResource: buffer_resource
                             r: r
                             g: g
                             b: b
                             a: a] release];
}

static const struct wp_single_pixel_buffer_manager_v1_interface
single_pixel_buffer_manager_impl = {
    .destroy = single_pixel_buffer_manager_destroy_handler,
    .create_u32_rgba_buffer = single_pixel_buffer_manager_create_u32_rgba_buffer_handler
};

static void single_pixel_buffer_manager_destroy(struct wl_resource *resource) {
    OwlWpSinglePixelBufferManagerV1 *self = wl_resource_get_user_data(resource);
    [self release];
}

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &single_pixel_buffer_manager_impl,
        [self retain],
        single_pixel_buffer_manager_destroy
    );
    return self;
}

static void single_pixel_buffer_manager_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &wp_single_pixel_buffer_manager_v1_interface,
        version,
        id
    );
    [[[OwlWpSinglePixelBufferManagerV1 alloc] initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    wl_global_create(
        display,
        &wp_single_pixel_buffer_manager_v1_interface,
        1,
        NULL,
        single_pixel_buffer_manager_bind
    );
}

@end
