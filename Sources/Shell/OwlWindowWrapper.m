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

#import "OwlWindowWrapper.h"
#import "OwlWindow.h"
#import <Cocoa/Cocoa.h>

@implementation OwlWindowWrapper

- (id) init {
    self = [super init];
    // Matches NSWindow's own unset-max default; contentMinSize's
    // NSZeroSize default already matches NSWindow's, so it needs no
    // explicit init. Roles that never touch min/max (e.g. wl_shell)
    // must still get an unclamped window out of -createWindow.
    _contentMaxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    return self;
}

- (void) dealloc {
    [_window release];
    [_title release];
    [_view release];
    [_windowDelegate release];
    [super dealloc];
}

- (void) createWindow {
    // Display native decorations (title bar, close button, resize
    // handles) by default. We advertise zxdg_decoration_manager_v1
    // and always answer "server side", so well-behaved clients
    // won't draw their own decorations. For clients that draw
    // them anyway, the SSD can be toggled off from the menu.
    _window = [[OwlWindow alloc] initWithSize: _size displaySSD: YES];
    [_window setContentMinSize: _contentMinSize];
    [_window setContentMaxSize: _contentMaxSize];

    if (_title != nil) {
        [_window setTitle: _title];
    }
    if (_view != nil) {
        [[_window contentView] addSubview: _view];
        [_window makeFirstResponder: _view];
    }
    [_window setDelegate: _windowDelegate];
}

- (void) map {
    if (_window == nil) {
        [self createWindow];
    }
    [_window makeKeyAndOrderFront: self];
}

- (void) unmap {
    [_window orderOut: self];
}

- (void) close {
    [_window close];
}

- (void) minimize {
    [_window miniaturize: self];
}

- (void) maximize {
    if (![_window isZoomed]) {
        [_window zoom: self];
    }
}

- (void) unmaximize {
    if ([_window isZoomed]) {
        [_window zoom: self];
    }
}

- (OwlWindow *) window {
    return _window;
}

- (void) setContentSize: (NSSize) size {
    _size = size;
    if (_window != nil
        && NSEqualSizes(
               [_window contentRectForFrameRect: [_window frame]].size,
               size)) {
        // Called on every surface commit; don't bother the
        // WindowServer (or trip -windowDidResize:) when the size
        // hasn't actually changed.
        return;
    }
    [_window setContentSize: _size];
}

- (void) setContentMinSize: (NSSize) size {
    _contentMinSize = size;
    if (_window != nil) {
        [_window setContentMinSize: size];
    }
}

- (void) setContentMaxSize: (NSSize) size {
    _contentMaxSize = size;
    if (_window != nil) {
        [_window setContentMaxSize: size];
    }
}

- (void) setTitle: (NSString *) title {
    [title retain];
    [_title release];
    _title = title;
    [_window setTitle: title];
}

- (void) setView: (NSView *) view {
    [view retain];
    [_view removeFromSuperview];
    [_view release];
    _view = view;
    [[_window contentView] addSubview: view];
    [_window makeFirstResponder: view];
}

- (void) setWindowDelegate: (id<NSWindowDelegate>) delegate {
    [delegate retain];
    [_windowDelegate release];
    _windowDelegate = delegate;
    [_window setDelegate: delegate];
}

@end
