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

#import "OwlGlobal.h"
#import <Cocoa/Cocoa.h>
#import <wayland-server.h>

@class OwlSurface;

/* Implements zwp_text_input_manager_v3.
 *
 * Owl itself is the input method: when a client enables its text
 * input (a text widget gained focus), OwlSurface routes plain key
 * events through -interpretKeyEvents:, and the Cocoa input context
 * answers through the NSTextInputClient methods — marked text
 * becomes preedit_string, inserted text becomes commit_string, and
 * non-text keys fall back to ordinary wl_keyboard events. That
 * gives clients dead keys, non-Latin layouts and full CJK
 * composition without any external IME protocol.
 *
 * enter/leave follow the keyboard focus (OwlKeyboard calls in
 * here); preedit/commit go to every enabled text input of the
 * focused client, each followed by done carrying that text input's
 * commit count, as the serial rules require. The global is offered
 * at version 1: the version 2 additions (actions, input panels)
 * have no Cocoa counterpart yet.
 */
@interface OwlZwpTextInputManagerV3 : NSObject <OwlGlobal> {
    struct wl_resource *_resource;
}

- (id) initWithResource: (struct wl_resource *) resource;

+ (void) addGlobalToDisplay: (struct wl_display *) display;

/* Keyboard focus tracking; called by OwlKeyboard right after its
 * own enter/leave events. */
+ (void) keyboardEnteredSurface: (OwlSurface *) surface;
+ (void) keyboardLeftSurface: (OwlSurface *) surface;

/* Whether the client of this surface has an enabled text input,
 * i.e. whether OwlSurface should hand plain keys to the Cocoa
 * input context instead of forwarding them raw. */
+ (BOOL) hasEnabledTextInputForSurfaceResource:
    (struct wl_resource *) surfaceResource;

/* Forward one input-method action to every enabled text input of
 * the surface's client, followed by done. Text may be nil to clear
 * the preedit. Cursor positions are byte offsets into the UTF-8
 * text, per the protocol. */
+ (void) sendPreeditString: (NSString *) text
               cursorBegin: (int32_t) cursorBegin
                 cursorEnd: (int32_t) cursorEnd
        forSurfaceResource: (struct wl_resource *) surfaceResource;
+ (void) sendCommitString: (NSString *) text
       forSurfaceResource: (struct wl_resource *) surfaceResource;

/* The cursor rectangle the client last committed, in surface-local
 * coordinates; NO if none is known. Feeds the position of the IME
 * candidate window via -firstRectForCharacterRange:. */
+ (BOOL) getCursorRectangle: (NSRect *) rect
         forSurfaceResource: (struct wl_resource *) surfaceResource;

@end
