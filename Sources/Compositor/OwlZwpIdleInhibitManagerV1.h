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


/* Implements zwp_idle_inhibit_manager_v1.
 *
 * Owl doesn't track per-surface visibility/occlusion, so this counts
 * every live inhibitor object as active (spec: "counting mapped
 * inhibitors is close enough for v1") and holds a single system power
 * assertion for as long as that count is above zero.
 */
@interface OwlZwpIdleInhibitManagerV1 : NSObject <OwlGlobal> {
    struct wl_resource *_resource;
}

- (id) initWithResource: (struct wl_resource *) resource;

+ (void) addGlobalToDisplay: (struct wl_display *) display;

@end
