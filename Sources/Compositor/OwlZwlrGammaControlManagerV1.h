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


/* Implements zwlr_gamma_control_manager_v1. There is at most one live
 * zwlr_gamma_control_v1 per display (CGDirectDisplayID) at a time; a
 * second get_gamma_control for an already-controlled display gets an
 * inert object that immediately sends "failed", per spec. On Apple,
 * gamma is applied with CGSetDisplayTransferByTable and restored with
 * CGDisplayRestoreColorSyncSettings on control destroy / disconnect.
 * On GNUstep, the global is registered but every control is inert
 * (compositor cannot adjust gamma), just to keep this file building
 * and exercised there. */
@interface OwlZwlrGammaControlManagerV1 : NSObject <OwlGlobal> {
    struct wl_resource *_resource;
}

- (id) initWithResource: (struct wl_resource *) resource;

+ (void) addGlobalToDisplay: (struct wl_display *) display;

@end
