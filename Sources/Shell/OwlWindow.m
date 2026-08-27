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
#import "OwlFeatures.h"
#import <Cocoa/Cocoa.h>

// Whether the left mouse button is physically held down right now.
// Interactive move/resize run a nested event loop that only a
// left-mouse-up terminates, but they are started by a client
// request that can arrive after the button was already released
// (or from a confused client). Entering the loop then would freeze
// the compositor until the next unrelated click; check the real
// button state instead of trusting the request.
static BOOL left_mouse_button_is_down(void) {
#if defined(OWL_PLATFORM_APPLE) && MAC_OS_X_VERSION_MAX_ALLOWED >= 1060
    if ([NSEvent respondsToSelector: @selector(pressedMouseButtons)]) {
        return ([NSEvent pressedMouseButtons] & 1) != 0;
    }
#endif
    // 10.5 / GNUstep: no global button-state query available;
    // assume the client is telling the truth.
    return YES;
}

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
    if (!left_mouse_button_is_down()) {
        return;
    }
    NSPoint originalMouseLocation = [NSEvent mouseLocation];
    NSPoint originalOrigin = [self frame].origin;
    NSEventMask mask = NSLeftMouseUpMask | NSMouseMovedMask | NSLeftMouseDraggedMask;

    while (YES) {
        // A finite timeout so the loop can double-check the button
        // state: the mouse-up can be lost to us (delivered to a
        // window that went away, swallowed by the system), and
        // waiting forever would freeze the compositor.
        NSEvent *event = [NSApp nextEventMatchingMask: mask
                                            untilDate: [NSDate dateWithTimeIntervalSinceNow: 0.25]
                                               inMode: NSEventTrackingRunLoopMode
                                              dequeue: YES];

        if (event == nil) {
            if (!left_mouse_button_is_down()) {
                break;
            }
            continue;
        }
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
    if (!left_mouse_button_is_down()) {
        return;
    }
    NSPoint originalMouseLocation = [NSEvent mouseLocation];
    NSRect originalFrame = [self frame];
    NSEventMask mask = NSLeftMouseUpMask | NSMouseMovedMask | NSLeftMouseDraggedMask;

    BOOL resizeTop = (edges & RESIZE_EDGE_TOP) != 0;
    BOOL resizeBottom = (edges & RESIZE_EDGE_BOTTOM) != 0;
    BOOL resizeLeft = (edges & RESIZE_EDGE_LEFT) != 0;
    BOOL resizeRight = (edges & RESIZE_EDGE_RIGHT) != 0;

    // Client resize limits (xdg_toplevel.set_min/max_size, already
    // applied to our real contentMinSize/contentMaxSize by the role
    // on every commit) are content sizes; convert to frame space,
    // the coordinate system -setFrame: below works in. A component
    // of 0 in contentMinSize, or CGFLOAT_MAX in contentMaxSize,
    // means the client set no limit on that axis (see
    // OwlWindowWrapper's default and OwlXdgToplevel -update).
    NSSize minContent = [self contentMinSize];
    NSSize maxContent = [self contentMaxSize];

    /* Minimum window size: 100.0 floor only when the client hasn't
     * asked for a minimum of its own. */
    CGFloat minWidth = 100.0;
    CGFloat minHeight = 100.0;
    if (minContent.width > 0) {
        minWidth = [self frameRectForContentRect:
            NSMakeRect(0, 0, minContent.width, 0)].size.width;
    }
    if (minContent.height > 0) {
        minHeight = [self frameRectForContentRect:
            NSMakeRect(0, 0, 0, minContent.height)].size.height;
    }

    /* Maximum window size: 0 means no cap. */
    CGFloat maxWidth = 0;
    CGFloat maxHeight = 0;
    if (maxContent.width < CGFLOAT_MAX) {
        maxWidth = [self frameRectForContentRect:
            NSMakeRect(0, 0, maxContent.width, 0)].size.width;
    }
    if (maxContent.height < CGFLOAT_MAX) {
        maxHeight = [self frameRectForContentRect:
            NSMakeRect(0, 0, 0, maxContent.height)].size.height;
    }

    while (YES) {
        // Finite timeout for the same reason as in
        // -runInteractiveMove: never wait forever on a mouse-up
        // that may already be gone.
        NSEvent *event = [NSApp nextEventMatchingMask: mask
                                            untilDate: [NSDate dateWithTimeIntervalSinceNow: 0.25]
                                               inMode: NSEventTrackingRunLoopMode
                                              dequeue: YES];

        if (event == nil) {
            if (!left_mouse_button_is_down()) {
                break;
            }
            continue;
        }
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
            if (maxWidth > 0 && newFrame.size.width > maxWidth) {
                newFrame.size.width = maxWidth;
            }
        }

        if (resizeLeft) {
            CGFloat newWidth = originalFrame.size.width - deltaX;
            if (newWidth < minWidth) {
                newWidth = minWidth;
                deltaX = originalFrame.size.width - minWidth;
            }
            if (maxWidth > 0 && newWidth > maxWidth) {
                newWidth = maxWidth;
                deltaX = originalFrame.size.width - maxWidth;
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
            if (maxHeight > 0 && newFrame.size.height > maxHeight) {
                newFrame.size.height = maxHeight;
            }
        }

        if (resizeBottom) {
            CGFloat newHeight = originalFrame.size.height - deltaY;
            if (newHeight < minHeight) {
                newHeight = minHeight;
                deltaY = originalFrame.size.height - minHeight;
            }
            if (maxHeight > 0 && newHeight > maxHeight) {
                newHeight = maxHeight;
                deltaY = originalFrame.size.height - maxHeight;
            }
            newFrame.size.height = newHeight;
            newFrame.origin.y = originalFrame.origin.y + deltaY;
        }

        [self setFrame: newFrame display: YES];
    }
}

@end
