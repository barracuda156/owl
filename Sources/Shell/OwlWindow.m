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

#import "OwlWindow.h"
#import <Cocoa/Cocoa.h>

@implementation OwlWindow

+ (NSUInteger) styleMaskWhenDisplayingSSD: (BOOL) displaySSD {
    if (!displaySSD) {
        return NSBorderlessWindowMask;
    }
    return NSTitledWindowMask | NSClosableWindowMask |
        NSMiniaturizableWindowMask | NSResizableWindowMask;
}

- (id) initWithSize: (NSSize) size displaySSD: (BOOL) displaySSD {
    NSRect contentRect;
    contentRect.origin = NSMakePoint(500, 500);
    contentRect.size = size;

    NSUInteger styleMask = [OwlWindow styleMaskWhenDisplayingSSD: displaySSD];
    self = [super initWithContentRect: contentRect
                            styleMask: styleMask
                              backing: NSBackingStoreBuffered
                                defer: NO];

    [self setOpaque: NO];
    [self setBackgroundColor: [NSColor clearColor]];
    [self setReleasedWhenClosed: NO];
    [self setAcceptsMouseMovedEvents: YES];

    // Does not automatically happen for borderless windows.
    [NSApp addWindowsItem: self title: @"Window" filename: NO];

    return self;
}

- (void) setTitle: (NSString *) newTitle {
    newTitle = [newTitle retain];
    [_title release];
    _title = newTitle;
    [super setTitle: newTitle];
    [NSApp changeWindowsItem: self title: newTitle filename: NO];
}

- (void) dealloc {
    [_title release];
    [super dealloc];
}

- (BOOL) displaySSD {
    return ([self styleMask] & NSTitledWindowMask) != 0;
}

- (void) setDisplaySSD: (BOOL) displaySSD {
    [self setStyleMask: [OwlWindow styleMaskWhenDisplayingSSD: displaySSD]];
    if (_title != nil) {
        [self setTitle: _title];
    }
}

- (IBAction) toggleDisplaySSD: (NSMenuItem *) sender {
    BOOL displaySSD = ![self displaySSD];
    [self setDisplaySSD: displaySSD];
    [sender setState: displaySSD];
}

- (BOOL) canBecomeKeyWindow {
    return YES;
}

- (BOOL) canBecomeMainWindow {
    return YES;
}

- (void) runInteractiveMove {
    NSPoint originalMouseLocation = [NSEvent mouseLocation];
    NSPoint originalOrigin = [self frame].origin;
    NSEventMask mask = NSLeftMouseUpMask | NSMouseMovedMask | NSLeftMouseDraggedMask;

    while (YES) {
        NSEvent *event = [NSApp nextEventMatchingMask: mask
                                            untilDate: [NSDate distantFuture]
                                               inMode: NSEventTrackingRunLoopMode
                                              dequeue: YES];

        if ([event type] == NSLeftMouseUp) {
            break;
        }

        NSPoint mouseLocation = [NSEvent mouseLocation];

        NSPoint origin = originalOrigin;
        origin.x += mouseLocation.x - originalMouseLocation.x;
        origin.y += mouseLocation.y - originalMouseLocation.y;
        [self setFrameOrigin: origin];
    }
}

/*
 * Resize edge values from xdg-shell protocol:
 * NONE = 0, TOP = 1, BOTTOM = 2, LEFT = 4, RIGHT = 8
 * TOP_LEFT = 5, BOTTOM_LEFT = 6, TOP_RIGHT = 9, BOTTOM_RIGHT = 10
 */
#define RESIZE_EDGE_TOP    1
#define RESIZE_EDGE_BOTTOM 2
#define RESIZE_EDGE_LEFT   4
#define RESIZE_EDGE_RIGHT  8

- (void) runInteractiveResizeWithEdges: (uint32_t) edges {
    NSPoint originalMouseLocation = [NSEvent mouseLocation];
    NSRect originalFrame = [self frame];
    NSEventMask mask = NSLeftMouseUpMask | NSMouseMovedMask | NSLeftMouseDraggedMask;

    BOOL resizeTop = (edges & RESIZE_EDGE_TOP) != 0;
    BOOL resizeBottom = (edges & RESIZE_EDGE_BOTTOM) != 0;
    BOOL resizeLeft = (edges & RESIZE_EDGE_LEFT) != 0;
    BOOL resizeRight = (edges & RESIZE_EDGE_RIGHT) != 0;

    /* Minimum window size */
    CGFloat minWidth = 100.0;
    CGFloat minHeight = 100.0;

    while (YES) {
        NSEvent *event = [NSApp nextEventMatchingMask: mask
                                            untilDate: [NSDate distantFuture]
                                               inMode: NSEventTrackingRunLoopMode
                                              dequeue: YES];

        if ([event type] == NSLeftMouseUp) {
            break;
        }

        NSPoint mouseLocation = [NSEvent mouseLocation];
        CGFloat deltaX = mouseLocation.x - originalMouseLocation.x;
        CGFloat deltaY = mouseLocation.y - originalMouseLocation.y;

        NSRect newFrame = originalFrame;

        if (resizeRight) {
            newFrame.size.width = originalFrame.size.width + deltaX;
            if (newFrame.size.width < minWidth) {
                newFrame.size.width = minWidth;
            }
        }

        if (resizeLeft) {
            CGFloat newWidth = originalFrame.size.width - deltaX;
            if (newWidth < minWidth) {
                newWidth = minWidth;
                deltaX = originalFrame.size.width - minWidth;
            }
            newFrame.size.width = newWidth;
            newFrame.origin.x = originalFrame.origin.x + deltaX;
        }

        /*
         * Note: In Cocoa, Y increases upward, and frame origin is bottom-left.
         * "Top" in Wayland (screen coordinates) = larger Y in Cocoa.
         * "Bottom" in Wayland = smaller Y in Cocoa.
         */
        if (resizeTop) {
            newFrame.size.height = originalFrame.size.height + deltaY;
            if (newFrame.size.height < minHeight) {
                newFrame.size.height = minHeight;
            }
        }

        if (resizeBottom) {
            CGFloat newHeight = originalFrame.size.height - deltaY;
            if (newHeight < minHeight) {
                newHeight = minHeight;
                deltaY = originalFrame.size.height - minHeight;
            }
            newFrame.size.height = newHeight;
            newFrame.origin.y = originalFrame.origin.y + deltaY;
        }

        [self setFrame: newFrame display: YES];
    }
}

@end
