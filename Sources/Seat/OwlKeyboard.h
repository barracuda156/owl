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

@class OwlSurface;

@interface OwlKeyboard : NSObject {
    struct wl_resource *_resource;
}

- (id) initWithResource: (struct wl_resource *) resource;

- (struct wl_resource *) resource;

+ (OwlKeyboard *) keyboardForClient: (struct wl_client *) client;

- (void) sendEnterSurface: (OwlSurface *) surface;
- (void) sendLeaveSurface: (OwlSurface *) surface;
- (void) sendKey: (unsigned short) keyCode isPressed: (BOOL) isPressed;
- (void) sendModifiers: (uint32_t) modifiers;

/* Translate an NSFlagsChanged event into modifier key events
 * plus a wl_keyboard.modifiers event. */
- (void) handleFlagsChanged: (NSEvent *) event;

/* Bring our idea of the modifier state in sync with the given
 * -[NSEvent modifierFlags] value. Cocoa delivers NSFlagsChanged
 * to the first responder of the key window, so we miss changes
 * that happen while the menu bar or another application has
 * focus; calling this from every event self-heals the state. */
- (void) reconcileModifierFlags: (NSUInteger) flags;

@end
