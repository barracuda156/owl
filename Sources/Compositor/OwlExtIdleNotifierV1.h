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

/* Implements ext_idle_notifier_v1.
 *
 * User idle time comes from CGEventSourceSecondsSinceLastEventType,
 * which counts all hardware input session-wide — exactly the "no
 * input to the seat" the protocol asks about, and it keeps working
 * while native apps have focus. Each notification runs a one-shot
 * NSTimer aimed at the moment its timeout would elapse, and while
 * idled polls once a second to catch the resume. On GNUstep there
 * is no such clock, so notifications simply never fire.
 *
 * Notifications created with get_idle_notification hold off while
 * any zwp_idle_inhibitor_v1 exists; get_input_idle_notification
 * (v2) ignores inhibitors, per the spec.
 */
@interface OwlExtIdleNotifierV1 : NSObject <OwlGlobal> {
    struct wl_resource *_resource;
}

- (id) initWithResource: (struct wl_resource *) resource;

+ (void) addGlobalToDisplay: (struct wl_display *) display;

@end
