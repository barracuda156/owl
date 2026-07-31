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

#import "OwlRegion.h"
#import <wayland-server.h>

@implementation OwlRegion

static void region_destroy(struct wl_resource *resource) {
    OwlRegion *self = wl_resource_get_user_data(resource);
    [self release];
}

static void region_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void region_append_op(
    struct wl_resource *resource,
    BOOL isAdd,
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height
) {
    OwlRegion *self = wl_resource_get_user_data(resource);
    struct OwlRegionOp op;
    op.isAdd = isAdd;
    op.rect = NSMakeRect(x, y, width, height);
    [self->_ops appendBytes: &op length: sizeof(op)];
}

static void region_add_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height
) {
    region_append_op(resource, YES, x, y, width, height);
}

static void region_subtract_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height
) {
    region_append_op(resource, NO, x, y, width, height);
}

static const struct wl_region_interface region_impl = {
    .destroy = region_destroy_handler,
    .add = region_add_handler,
    .subtract = region_subtract_handler
};


- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    _ops = [NSMutableData new];
    wl_resource_set_implementation(
        resource,
        &region_impl,
        [self retain],
        region_destroy
    );
    return self;
}

- (void) dealloc {
    [_ops release];
    [super dealloc];
}

- (NSData *) opsSnapshot {
    return [NSData dataWithData: _ops];
}

+ (BOOL) ops: (NSData *) ops containPoint: (NSPoint) point {
    const struct OwlRegionOp *op = [ops bytes];
    NSUInteger i, count = [ops length] / sizeof(*op);
    BOOL contained = NO;

    for (i = 0; i < count; i++) {
        if (NSPointInRect(point, op[i].rect)) {
            contained = op[i].isAdd;
        }
    }
    return contained;
}

+ (BOOL) opsCanEverContainPoints: (NSData *) ops {
    const struct OwlRegionOp *op = [ops bytes];
    NSUInteger i, count = [ops length] / sizeof(*op);

    for (i = 0; i < count; i++) {
        if (op[i].isAdd) {
            return YES;
        }
    }
    return NO;
}

@end
