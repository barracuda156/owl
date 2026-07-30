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


/* Holds the rules accumulated on an xdg_positioner object and
 * computes the resulting popup geometry from them. Owl does not
 * implement constraint_adjustment (flip/slide/resize against screen
 * edges); the popup is placed at the anchor+gravity+offset position
 * unconditionally, which is spec-compliant for constraint_adjustment
 * "none" and a reasonable approximation otherwise.
 */
@interface OwlXdgPositioner : NSObject {
@public
    NSSize _size;
    NSRect _anchorRect;
    // enum xdg_positioner_anchor / _gravity values; stored as plain
    // uint32_t because the generated xdg-shell.h that defines those
    // enums is not visible from this header.
    uint32_t _anchor;
    uint32_t _gravity;
    uint32_t _constraintAdjustment;
    NSPoint _offset;
}

// Returns the popup's window-geometry rect, positioned relative to
// the parent's window geometry origin (i.e. the rect the protocol's
// xdg_popup.configure x/y/width/height should carry).
- (NSRect) geometryRelativeToParent;

@end
