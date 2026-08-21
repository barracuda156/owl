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

#import "OwlPopupWindow.h"

@implementation OwlPopupWindow

- (id) initWithContentRect: (NSRect) contentRect {
    self = [super initWithContentRect: contentRect
                            styleMask: NSBorderlessWindowMask
                              backing: NSBackingStoreBuffered
                                defer: NO];

    [self setOpaque: NO];
    [self setBackgroundColor: [NSColor clearColor]];
    [self setReleasedWhenClosed: NO];
    [self setAcceptsMouseMovedEvents: YES];
    [self setExcludedFromWindowsMenu: YES];
    // The client's own drop shadow, if it draws one, is clipped
    // away along with the rest of the window-geometry margins;
    // give the popup a native shadow instead.
    [self setHasShadow: YES];

    return self;
}

- (BOOL) canBecomeKeyWindow {
    return YES;
}

@end
