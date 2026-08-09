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


/* zwp_primary_selection_device_v1: the same focus-tracked selection
 * replay as OwlWlDataDevice, but for the primary selection and with
 * no drag-and-drop support (the protocol has none). */
@interface OwlZwpPrimarySelectionDeviceV1 : OwlDataDevice {
    NSUInteger _focusCount;
    BOOL _selectionHasChangedSinceLastFocused;
}

+ (OwlZwpPrimarySelectionDeviceV1 *) deviceForClient: (struct wl_client *) client;

- (void) focused;
- (void) unfocused;

@end
