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

#import "OwlAppDelegate.h"
#import "OwlServer.h"

@implementation OwlAppDelegate

// The main menu nib predates copy/paste support, so add the Edit
// menu here. The items target the first responder, which is the
// focused client's view; it types the client's own clipboard keys
// in response (see -[OwlSurface copy:]).
- (void) installEditMenu {
    NSMenu *mainMenu = [NSApp mainMenu];
    NSMenu *editMenu;
    NSMenuItem *item;
    NSInteger index;

    if (mainMenu == nil || [mainMenu indexOfItemWithTitle: @"Edit"] >= 0) {
        return;
    }

    editMenu = [[NSMenu alloc] initWithTitle: @"Edit"];

    item = [[NSMenuItem alloc] initWithTitle: @"Copy"
                                      action: @selector(copy:)
                               keyEquivalent: @"c"];
    [editMenu addItem: item];
    [item release];

    item = [[NSMenuItem alloc] initWithTitle: @"Paste"
                                      action: @selector(paste:)
                               keyEquivalent: @"v"];
    [editMenu addItem: item];
    [item release];

    item = [[NSMenuItem alloc] initWithTitle: @"Edit"
                                      action: NULL
                               keyEquivalent: @""];
    [item setSubmenu: editMenu];
    [editMenu release];

    // Conventionally right after the application menu.
    index = [mainMenu numberOfItems] > 0 ? 1 : 0;
    [mainMenu insertItem: item atIndex: index];
    [item release];
}

- (void) applicationDidFinishLaunching: (NSNotification *) notification {
    [self installEditMenu];

    // Instantiate the server. If sucessful, this will
    // automatically start serving the clients.
    OwlServer *server = [OwlServer sharedServer];
    if (server == nil) {
        // It should have already displayed an error message,
        // so we just to have to exit. We call exit() directly
        // instead of using -[NSApp terminate:] in order to
        // have it return the non-zero exit code. We should
        // not have any unsaved documents anyway.
        exit(1);
    }
}

- (void) applicationWillBecomeActive: (NSNotification *) notification {
    // Force the pasteboard to reload its contents.
    [[NSPasteboard generalPasteboard] types];
}

@end
