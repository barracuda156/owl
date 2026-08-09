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

@class OwlOutput;

/* zxdg_output_v1: a thin, static wrapper over OwlOutput's NSScreen
 * frame. Owl never tracks screen reconfiguration at runtime (nothing
 * else in the compositor does either), so the whole event burst is
 * sent once at construction and no reference to the wl_output or its
 * OwlOutput is kept around afterwards. */
@interface OwlZxdgOutputV1 : NSObject {
    struct wl_resource *_resource;
}

// outputResource is the wl_output this xdg_output was created for
// (see zxdg_output_manager_v1.get_xdg_output); it is only used to
// send wl_output.done once the initial xdg_output burst is out, per
// the version-3 done semantics.
- (id) initWithResource: (struct wl_resource *) resource
                  output: (OwlOutput *) output
          outputResource: (struct wl_resource *) outputResource;

@end
