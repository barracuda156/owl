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


// anchor/gravity flip helpers for constraint_adjustment's flip_x/
// flip_y. xdg_positioner_anchor and xdg_positioner_gravity share
// the exact same numeric encoding (none=0, top=1, bottom=2, left=3,
// right=4, top_left=5, bottom_left=6, top_right=7, bottom_right=8 --
// verified against the vendored xdg-shell.xml), so one pair of
// uint32_t helpers serves both. Each only ever touches the
// component named in its own axis, so flipping x leaves a value's y
// contribution (and vice versa) unchanged -- e.g. top_left flipped
// on x becomes top_right, never bottom_left.
static uint32_t flippedOnX(uint32_t value) {
    switch (value) {
    case XDG_POSITIONER_ANCHOR_LEFT: return XDG_POSITIONER_ANCHOR_RIGHT;
    case XDG_POSITIONER_ANCHOR_RIGHT: return XDG_POSITIONER_ANCHOR_LEFT;
    case XDG_POSITIONER_ANCHOR_TOP_LEFT: return XDG_POSITIONER_ANCHOR_TOP_RIGHT;
    case XDG_POSITIONER_ANCHOR_TOP_RIGHT: return XDG_POSITIONER_ANCHOR_TOP_LEFT;
    case XDG_POSITIONER_ANCHOR_BOTTOM_LEFT: return XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT;
    case XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT: return XDG_POSITIONER_ANCHOR_BOTTOM_LEFT;
    default: return value;
    }
}

static uint32_t flippedOnY(uint32_t value) {
    switch (value) {
    case XDG_POSITIONER_ANCHOR_TOP: return XDG_POSITIONER_ANCHOR_BOTTOM;
    case XDG_POSITIONER_ANCHOR_BOTTOM: return XDG_POSITIONER_ANCHOR_TOP;
    case XDG_POSITIONER_ANCHOR_TOP_LEFT: return XDG_POSITIONER_ANCHOR_BOTTOM_LEFT;
    case XDG_POSITIONER_ANCHOR_BOTTOM_LEFT: return XDG_POSITIONER_ANCHOR_TOP_LEFT;
    case XDG_POSITIONER_ANCHOR_TOP_RIGHT: return XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT;
    case XDG_POSITIONER_ANCHOR_BOTTOM_RIGHT: return XDG_POSITIONER_ANCHOR_TOP_RIGHT;
    default: return value;
    }
}

@implementation OwlXdgPositioner

// The anchor point on the anchor rectangle, in the coordinate space
// of the parent's window geometry (Wayland: y grows downward), for
// an arbitrary anchor value -- factored out of -anchorPoint so the
// flip step below can recompute it for a flipped anchor without
// mutating _anchor itself.
- (NSPoint) anchorPointForAnchor: (uint32_t) anchor {
    NSPoint p = NSMakePoint(
        NSMidX(_anchorRect),
        NSMidY(_anchorRect)
    );

    switch (anchor) {
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

- (NSPoint) anchorPoint {
    return [self anchorPointForAnchor: _anchor];
}

- (NSRect) geometryWithAnchor: (uint32_t) anchor gravity: (uint32_t) gravity {
    NSPoint anchorPoint = [self anchorPointForAnchor: anchor];
    NSPoint origin = anchorPoint;

    // The gravity determines which corner of the popup sits at the
    // anchor point; center on an axis with no gravity specified.
    switch (gravity) {
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

- (NSRect) geometryRelativeToParent {
    return [self geometryWithAnchor: _anchor gravity: _gravity];
}

- (NSRect) geometryRelativeToParentConstrainedTo: (NSRect) box {
    NSRect rect = [self geometryRelativeToParent];

    // 1. Flip: only kept if it fully unconstrains the axis: a
    // partial improvement is not a win per spec ("the resulting
    // position ... will be the one before the adjustment").
    BOOL constrainedX = NSMinX(rect) < NSMinX(box) || NSMaxX(rect) > NSMaxX(box);
    if ((_constraintAdjustment & XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_X)
        && constrainedX) {
        NSRect flipped = [self geometryWithAnchor: flippedOnX(_anchor)
                                           gravity: flippedOnX(_gravity)];
        if (NSMinX(flipped) >= NSMinX(box) && NSMaxX(flipped) <= NSMaxX(box)) {
            rect.origin.x = flipped.origin.x;
        }
    }
    BOOL constrainedY = NSMinY(rect) < NSMinY(box) || NSMaxY(rect) > NSMaxY(box);
    if ((_constraintAdjustment & XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_FLIP_Y)
        && constrainedY) {
        NSRect flipped = [self geometryWithAnchor: flippedOnY(_anchor)
                                           gravity: flippedOnY(_gravity)];
        if (NSMinY(flipped) >= NSMinY(box) && NSMaxY(flipped) <= NSMaxY(box)) {
            rect.origin.y = flipped.origin.y;
        }
    }

    // 2. Slide: push the rect back inside the box; a rect larger
    // than the box on this axis pins to box.min (the max-edge
    // correction runs first, so the following min-edge correction
    // is what wins for an oversized rect).
    if (_constraintAdjustment & XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_X) {
        if (NSMaxX(rect) > NSMaxX(box)) {
            rect.origin.x += NSMaxX(box) - NSMaxX(rect);
        }
        if (NSMinX(rect) < NSMinX(box)) {
            rect.origin.x += NSMinX(box) - NSMinX(rect);
        }
    }
    if (_constraintAdjustment & XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_SLIDE_Y) {
        if (NSMaxY(rect) > NSMaxY(box)) {
            rect.origin.y += NSMaxY(box) - NSMaxY(rect);
        }
        if (NSMinY(rect) < NSMinY(box)) {
            rect.origin.y += NSMinY(box) - NSMinY(rect);
        }
    }

    // 3. Resize: clamp both edges into the box, flooring the size
    // at 1 so a box narrower/shorter than the popup doesn't invert
    // the rect.
    if (_constraintAdjustment & XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_RESIZE_X) {
        CGFloat minX = (NSMinX(rect) < NSMinX(box)) ? NSMinX(box) : NSMinX(rect);
        CGFloat maxX = (NSMaxX(rect) > NSMaxX(box)) ? NSMaxX(box) : NSMaxX(rect);
        if (maxX - minX < 1) {
            maxX = minX + 1;
        }
        rect.origin.x = minX;
        rect.size.width = maxX - minX;
    }
    if (_constraintAdjustment & XDG_POSITIONER_CONSTRAINT_ADJUSTMENT_RESIZE_Y) {
        CGFloat minY = (NSMinY(rect) < NSMinY(box)) ? NSMinY(box) : NSMinY(rect);
        CGFloat maxY = (NSMaxY(rect) > NSMaxY(box)) ? NSMaxY(box) : NSMaxY(rect);
        if (maxY - minY < 1) {
            maxY = minY + 1;
        }
        rect.origin.y = minY;
        rect.size.height = maxY - minY;
    }

    return rect;
}

@end
