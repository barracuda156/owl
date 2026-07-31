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

#import "OwlDataDevice.h"
#import <Cocoa/Cocoa.h>
#import <wayland-server.h>


@class OwlDataSource;
@class OwlSurface;
@class OwlWlDataOffer;

@interface OwlWlDataDevice : OwlDataDevice {
    NSUInteger _focusCount;
    BOOL _selectionHasChangedSinceLastFocused;
    // The offer of the drag-and-drop session currently hovering
    // over one of this client's surfaces, if any.
    OwlWlDataOffer *_dndOffer;
}

+ (OwlWlDataDevice *) dataDeviceForClient: (struct wl_client *) client;

- (void) focused;
- (void) unfocused;

/* Compositor-initiated drag-and-drop (e.g. a file dragged in
 * from the Finder), following the same enter/motion/leave/drop
 * shape as Cocoa's NSDraggingDestination. */
- (void) dndEnterSurface: (OwlSurface *) surface
                 atPoint: (NSPoint) point
          withDataSource: (OwlDataSource *) dataSource;
- (void) dndMotionAtPoint: (NSPoint) point;
- (void) dndLeave;
- (void) dndDrop;
- (BOOL) isDndInProgress;

@end
