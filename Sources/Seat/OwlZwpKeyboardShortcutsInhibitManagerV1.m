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

#import "OwlZwpKeyboardShortcutsInhibitManagerV1.h"
#import "keyboard-shortcuts-inhibit-unstable-v1.h"


/* One zwp_keyboard_shortcuts_inhibitor_v1, keyed to the wl_surface
 * it was created for. The seat argument is not kept: owl only has
 * one seat. */
@interface OwlZwpKeyboardShortcutsInhibitor : NSObject {
@public
    struct wl_resource *_resource;
    struct wl_resource *_surfaceResource;
    struct wl_listener _surfaceDestroyListener;
}

- (id) initWithResource: (struct wl_resource *) resource
        surfaceResource: (struct wl_resource *) surfaceResource;

@end

@implementation OwlZwpKeyboardShortcutsInhibitor

static NSMutableArray *inhibitors;

+ (void) initialize {
    if (inhibitors == nil) {
        inhibitors = [[NSMutableArray alloc] initWithCapacity: 1];
    }
}

+ (OwlZwpKeyboardShortcutsInhibitor *) inhibitorForSurfaceResource:
    (struct wl_resource *) surfaceResource
{
    for (OwlZwpKeyboardShortcutsInhibitor *inhibitor in inhibitors) {
        if (inhibitor->_surfaceResource == surfaceResource) {
            return inhibitor;
        }
    }
    return nil;
}

static void inhibitor_surface_destroy_notify(
    struct wl_listener *listener,
    void *data
) {
    OwlZwpKeyboardShortcutsInhibitor *self = nil;
    for (OwlZwpKeyboardShortcutsInhibitor *inhibitor in inhibitors) {
        if (&inhibitor->_surfaceDestroyListener == listener) {
            self = inhibitor;
            break;
        }
    }
    if (self == nil) {
        return;
    }

    self->_surfaceResource = NULL;
    wl_list_remove(&self->_surfaceDestroyListener.link);
    wl_list_init(&self->_surfaceDestroyListener.link);
}

static void inhibitor_destroy(struct wl_resource *resource) {
    OwlZwpKeyboardShortcutsInhibitor *self =
        wl_resource_get_user_data(resource);
    [inhibitors removeObjectIdenticalTo: self];
    [self release];
}

static void inhibitor_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static const struct zwp_keyboard_shortcuts_inhibitor_v1_interface
inhibitor_impl = {
    .destroy = inhibitor_destroy_handler
};

- (id) initWithResource: (struct wl_resource *) resource
        surfaceResource: (struct wl_resource *) surfaceResource
{
    _resource = resource;
    _surfaceResource = surfaceResource;
    _surfaceDestroyListener.notify = inhibitor_surface_destroy_notify;
    wl_resource_add_destroy_listener(
        surfaceResource,
        &_surfaceDestroyListener
    );
    [inhibitors addObject: self];

    wl_resource_set_implementation(
        resource,
        &inhibitor_impl,
        [self retain],
        inhibitor_destroy
    );

    // Owl always grants the inhibition, and never revokes it while
    // the object lives.
    zwp_keyboard_shortcuts_inhibitor_v1_send_active(resource);

    return self;
}

- (void) dealloc {
    if (_surfaceResource != NULL) {
        wl_list_remove(&_surfaceDestroyListener.link);
    }
    [super dealloc];
}

@end


@implementation OwlZwpKeyboardShortcutsInhibitManagerV1

+ (BOOL) shortcutsInhibitedForSurfaceResource:
    (struct wl_resource *) surfaceResource
{
    if (surfaceResource == NULL) {
        return NO;
    }
    OwlZwpKeyboardShortcutsInhibitor *inhibitor =
        [OwlZwpKeyboardShortcutsInhibitor
            inhibitorForSurfaceResource: surfaceResource];
    return inhibitor != nil;
}

static void shortcuts_inhibit_manager_destroy(struct wl_resource *resource) {
    OwlZwpKeyboardShortcutsInhibitManagerV1 *self =
        wl_resource_get_user_data(resource);
    [self release];
}

static void shortcuts_inhibit_manager_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void shortcuts_inhibit_manager_inhibit_shortcuts_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    struct wl_resource *surface_resource,
    struct wl_resource *seat_resource
) {
    OwlZwpKeyboardShortcutsInhibitor *existing =
        [OwlZwpKeyboardShortcutsInhibitor
            inhibitorForSurfaceResource: surface_resource];
    // NULL rather than nil: GCC's ObjC headers define nil as (id)0,
    // which fails to parse in functions whose id parameter shadows
    // the id type, like this wayland request handler.
    if (existing != NULL) {
        wl_resource_post_error(
            resource,
            ZWP_KEYBOARD_SHORTCUTS_INHIBIT_MANAGER_V1_ERROR_ALREADY_INHIBITED,
            "wl_surface@%u already has a shortcuts inhibitor",
            wl_resource_get_id(surface_resource)
        );
        return;
    }

    struct wl_resource *inhibitor_resource = wl_resource_create(
        client,
        &zwp_keyboard_shortcuts_inhibitor_v1_interface,
        wl_resource_get_version(resource),
        id
    );
    OwlZwpKeyboardShortcutsInhibitor *inhibitor =
        [OwlZwpKeyboardShortcutsInhibitor alloc];
    [[inhibitor initWithResource: inhibitor_resource
                 surfaceResource: surface_resource] release];
}

static const struct zwp_keyboard_shortcuts_inhibit_manager_v1_interface
shortcuts_inhibit_manager_impl = {
    .destroy = shortcuts_inhibit_manager_destroy_handler,
    .inhibit_shortcuts = shortcuts_inhibit_manager_inhibit_shortcuts_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &shortcuts_inhibit_manager_impl,
        [self retain],
        shortcuts_inhibit_manager_destroy
    );
    return self;
}

static void shortcuts_inhibit_manager_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &zwp_keyboard_shortcuts_inhibit_manager_v1_interface,
        version,
        id
    );
    OwlZwpKeyboardShortcutsInhibitManagerV1 *self =
        [OwlZwpKeyboardShortcutsInhibitManagerV1 alloc];
    [[self initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    wl_global_create(
        display,
        &zwp_keyboard_shortcuts_inhibit_manager_v1_interface,
        1,
        NULL,
        shortcuts_inhibit_manager_bind
    );
}

@end
