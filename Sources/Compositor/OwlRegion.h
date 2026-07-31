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

#import <Cocoa/Cocoa.h>
#import <wayland-server.h>

// One building operation of a wl_region. A region's effective
// contents are the result of replaying its operations in order.
struct OwlRegionOp {
    BOOL isAdd;
    NSRect rect;
};

@interface OwlRegion : NSObject {
    struct wl_resource *_resource;
    // A sequence of struct OwlRegionOp.
    NSMutableData *_ops;
}

- (id) initWithResource: (struct wl_resource *) resource;

// An immutable snapshot of the operations, suitable for keeping in
// a surface state after this region object is destroyed (clients
// may destroy the wl_region right after e.g. set_input_region).
// Never nil: an empty region gives an empty snapshot. "No region
// set at all" is represented by nil at the call sites instead.
- (NSData *) opsSnapshot;

+ (BOOL) ops: (NSData *) ops containPoint: (NSPoint) point;

// Whether the region could contain any point at all. Conservative:
// a region whose adds were later all subtracted again still
// reports YES, but the per-point queries remain exact.
+ (BOOL) opsCanEverContainPoints: (NSData *) ops;

@end
