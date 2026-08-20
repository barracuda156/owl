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

#import "OwlGlobal.h"
#import <Cocoa/Cocoa.h>
#import <wayland-server.h>

/* Implements zwp_relative_pointer_manager_v1.
 *
 * Relative motion comes from -[NSEvent deltaX/deltaY], which Cocoa
 * keeps delivering even when the cursor is pinned in place (the
 * pointer-lock case this protocol exists for). Cocoa only exposes
 * accelerated deltas, so the unaccelerated pair carries the same
 * values.
 */
@interface OwlZwpRelativePointerManagerV1 : NSObject <OwlGlobal> {
    struct wl_resource *_resource;
}

- (id) initWithResource: (struct wl_resource *) resource;

+ (void) addGlobalToDisplay: (struct wl_display *) display;

/* Send relative_motion to every zwp_relative_pointer_v1 of the
 * given client, as part of the same pointer frame the caller is
 * building (OwlPointer sends this right before motion + frame). */
+ (void) sendRelativeMotionForClient: (struct wl_client *) client
                              deltaX: (CGFloat) deltaX
                              deltaY: (CGFloat) deltaY;

@end
