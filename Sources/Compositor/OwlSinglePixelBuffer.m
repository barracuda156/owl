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

#import "OwlSinglePixelBuffer.h"


@implementation OwlSinglePixelBuffer

- (id) initWithResource: (struct wl_resource *) resource
                       r: (uint32_t) r
                       g: (uint32_t) g
                       b: (uint32_t) b
                       a: (uint32_t) a
{
    self = [super initWithResource: resource];

    // Per the protocol, these values use premultiplied alpha and are
    // expressed as a fraction of UINT32_MAX.
    _alpha = a / 4294967295.0;
    _red = r / 4294967295.0;
    _green = g / 4294967295.0;
    _blue = b / 4294967295.0;

    return self;
}

- (NSSize) size {
    return NSMakeSize(1, 1);
}

- (BOOL) needsGLForRendering {
    return NO;
}

- (NSColor *) color {
    // Un-premultiply so NSColor gets straight alpha components.
    if (_alpha == 0.0) {
        return [NSColor colorWithCalibratedRed: 0.0 green: 0.0 blue: 0.0 alpha: 0.0];
    }
    return [NSColor colorWithCalibratedRed: _red / _alpha
                                      green: _green / _alpha
                                       blue: _blue / _alpha
                                      alpha: _alpha];
}

- (void) drawInRect: (NSRect) rect {
    [[self color] set];
    NSRectFillUsingOperation(rect, NSCompositeSourceOver);
}

- (NSImage *) createNSImage {
    NSSize size = NSMakeSize(1, 1);
    NSImage *image = [[NSImage alloc] initWithSize: size];
    [image lockFocus];
    [[self color] set];
    NSRectFillUsingOperation(NSMakeRect(0, 0, 1, 1), NSCompositeSourceOver);
    [image unlockFocus];
    return image;
}

@end
