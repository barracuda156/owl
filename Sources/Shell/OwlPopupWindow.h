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

/* The borderless window that hosts an xdg_popup surface (a menu,
 * a combobox popdown, a tooltip). It is attached to its parent's
 * window as a child window, so it follows the parent around. It
 * can become the key window: a popup with a grab is supposed to
 * take the keyboard focus (that's how menus get their Escape and
 * arrow keys), and Cocoa only routes mouse-moved events to the
 * key window, which the client needs for hover highlights. */
@interface OwlPopupWindow : NSWindow

- (id) initWithContentRect: (NSRect) contentRect;

@end
