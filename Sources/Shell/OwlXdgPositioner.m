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

#import "OwlXdgPositioner.h"
#import "xdg-shell.h"


@implementation OwlXdgPositioner

// The anchor point on the anchor rectangle, in the coordinate space
// of the parent's window geometry (Wayland: y grows downward).
- (NSPoint) anchorPoint {
    NSPoint p = NSMakePoint(
        NSMidX(_anchorRect),
        NSMidY(_anchorRect)
    );

    switch (_anchor) {
    case XDG_POSITIONER_ANCHOR_TOP:
        p.y = NSMinY(_anchorRect);
        break;
    case XDG_POSITIONER_ANCHOR_BOTTOM:
        p.y = NSMaxY(_anchorRect);
        break;
    case XDG_POSITIONER_ANCHOR_LEFT:
        p.x = NSMinX(_anchorRect);
        break;
    case XDG_POSITIONER_ANCHOR_RIGHT:
        p.x = NSMaxX(_anchorRect);
        break;
    case XDG_POSITIONER_ANCHOR_TOP_LEFT:
        p.x = NSMinX(_anchorRect);
        p.y = NSMinY(_anchorRect);
        break;
    case XDG_POSITIONER_ANCHOR_BOTTOM_LEFT:
        p.x = NSMinX(_anchorRect);
        p.y = NSMaxY(_anchorRect);
        break;
    case XDG_POSITIONER_ANCHOR_TOP_RIGHT:
        p.x = NSMaxX(_anchorRect);
        p.y = NSMinY(_anchorRect);
        break;
    case XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT:
        p.x = NSMaxX(_anchorRect);
        p.y = NSMaxY(_anchorRect);
        break;
    case XDG_POSITIONER_ANCHOR_NONE:
    default:
        break;
    }

    return p;
}

- (NSRect) geometryRelativeToParent {
    NSPoint anchor = [self anchorPoint];
    NSPoint origin = anchor;

    // The gravity determines which corner of the popup sits at the
    // anchor point; center on an axis with no gravity specified.
    switch (_gravity) {
    case XDG_POSITIONER_GRAVITY_TOP:
        origin.x -= _size.width / 2;
        origin.y -= _size.height;
        break;
    case XDG_POSITIONER_GRAVITY_BOTTOM:
        origin.x -= _size.width / 2;
        break;
    case XDG_POSITIONER_GRAVITY_LEFT:
        origin.x -= _size.width;
        origin.y -= _size.height / 2;
        break;
    case XDG_POSITIONER_GRAVITY_RIGHT:
        origin.y -= _size.height / 2;
        break;
    case XDG_POSITIONER_GRAVITY_TOP_LEFT:
        origin.x -= _size.width;
        origin.y -= _size.height;
        break;
    case XDG_POSITIONER_GRAVITY_BOTTOM_LEFT:
        origin.x -= _size.width;
        break;
    case XDG_POSITIONER_GRAVITY_TOP_RIGHT:
        origin.y -= _size.height;
        break;
    case XDG_POSITIONER_GRAVITY_BOTTOM_RIGHT:
        break;
    case XDG_POSITIONER_GRAVITY_NONE:
    default:
        origin.x -= _size.width / 2;
        origin.y -= _size.height / 2;
        break;
    }

    origin.x += _offset.x;
    origin.y += _offset.y;

    return NSMakeRect(origin.x, origin.y, _size.width, _size.height);
}

@end
