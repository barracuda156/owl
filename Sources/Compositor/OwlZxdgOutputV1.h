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

/* zxdg_output_v1: a thin wrapper over OwlOutput's NSScreen frame,
 * re-sent on -refresh whenever OwlOutput's hot-plug handler decides
 * the underlying display's geometry may have changed. */
@interface OwlZxdgOutputV1 : NSObject {
    struct wl_resource *_resource;
    // outputResource is the wl_output this xdg_output was created
    // for (see zxdg_output_manager_v1.get_xdg_output); only used to
    // send wl_output.done once a burst is out, per the version-3
    // done semantics. Foreign resource -- destroyed independently of
    // us, so it is watched and nulled out via a destroy listener the
    // same way OwlXdgToplevel watches its set_parent target.
    struct wl_resource *_outputResource;
    struct wl_listener _outputResourceDestroyListener;
    // The display this xdg_output mirrors, captured at construction
    // time. Kept as a display ID rather than a retained OwlOutput* so
    // -refresh can re-resolve the live NSScreen independently of
    // whatever order OwlOutput's own hot-plug bookkeeping runs in.
    uint32_t _displayID;
}

- (id) initWithResource: (struct wl_resource *) resource
                  output: (OwlOutput *) output
          outputResource: (struct wl_resource *) outputResource;

// Re-send the logical position/size (+ terminating done) for the
// live NSScreen of this xdg_output's display. No-op if that display
// is no longer present.
- (void) refresh;

// Fan -refresh over every live xdg_output mirroring displayID.
+ (void) refreshDisplayID: (uint32_t) displayID;

@end
