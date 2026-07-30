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


/* One wp_presentation_feedback object. Much like an OwlCallback,
 * except that it either completes with presented or with discarded
 * (both destructor events), and that it survives its resource being
 * destroyed first (e.g. on client disconnect): the send methods
 * simply become no-ops then.
 */
@interface OwlWpPresentationFeedback : NSObject {
@public
    struct wl_resource *_resource;
}

- (id) initWithResource: (struct wl_resource *) resource;

// Send presented with the current presentation clock time and
// destroy the feedback resource. Owl presents via Quartz with no
// vsync, hardware timestamp or zero-copy guarantees and no way to
// predict the next refresh, so the refresh interval, retrace
// counter and flags arguments are all zero.
- (void) sendPresented;
// Send discarded and destroy the feedback resource.
- (void) sendDiscarded;

@end


/* Implements wp_presentation (the presentation-time protocol).
 * Feedback objects are queued on the surface's pending state and
 * completed from the surface's drawing path; mpv uses this to
 * estimate display timing.
 */
@interface OwlWpPresentation : NSObject <OwlGlobal> {
    struct wl_resource *_resource;
}

- (id) initWithResource: (struct wl_resource *) resource;

+ (void) addGlobalToDisplay: (struct wl_display *) display;

@end
