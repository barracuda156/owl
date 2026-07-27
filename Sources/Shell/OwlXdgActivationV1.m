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

#import "OwlXdgActivationV1.h"
#import "OwlSurface.h"
#import "OwlXdgToplevel.h"
#import "OwlWindowWrapper.h"
#import "OwlWindow.h"
#import "xdg-activation-v1.h"
#import <wayland-server.h>


@interface OwlXdgActivationTokenV1 : NSObject {
@public
    struct wl_resource *_resource;
}

- (id) initWithResource: (struct wl_resource *) resource;

@end

@implementation OwlXdgActivationTokenV1

static void activation_token_destroy(struct wl_resource *resource) {
    OwlXdgActivationTokenV1 *self = wl_resource_get_user_data(resource);
    [self release];
}

static void activation_token_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void activation_token_set_serial_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t serial,
    struct wl_resource *seat_resource
) {
    // Not tracked: tokens are not validated on activate.
}

static void activation_token_set_app_id_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    const char *app_id
) {
    // Not tracked: tokens are not validated on activate.
}

static void activation_token_set_surface_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *surface_resource
) {
    // Not tracked: tokens are not validated on activate.
}

static void activation_token_commit_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    static unsigned counter;
    char token[32];
    snprintf(token, sizeof(token), "owl-%u", ++counter);
    xdg_activation_token_v1_send_done(resource, token);
}

static const struct xdg_activation_token_v1_interface
activation_token_impl = {
    .set_serial = activation_token_set_serial_handler,
    .set_app_id = activation_token_set_app_id_handler,
    .set_surface = activation_token_set_surface_handler,
    .commit = activation_token_commit_handler,
    .destroy = activation_token_destroy_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &activation_token_impl,
        [self retain],
        activation_token_destroy
    );
    return self;
}

@end


@implementation OwlXdgActivationV1

static void activation_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void activation_get_activation_token_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id
) {
    struct wl_resource *token_resource = wl_resource_create(
        client,
        &xdg_activation_token_v1_interface,
        wl_resource_get_version(resource),
        id
    );
    [[[OwlXdgActivationTokenV1 alloc] initWithResource: token_resource] release];
}

static void activation_activate_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    const char *token,
    struct wl_resource *surface_resource
) {
    // No token validation store: any token (including none we
    // issued) is accepted, matching the lenient v1 behavior noted
    // in the brief.
    OwlSurface *surface = wl_resource_get_user_data(surface_resource);
    if (surface == nil) {
        return;
    }
    id<OwlSurfaceRole> role = [surface role];
    if (![role isKindOfClass: [OwlXdgToplevel class]]) {
        return;
    }
    OwlWindowWrapper *wrapper = [(OwlXdgToplevel *) role windowWrapper];
    if (wrapper == nil) {
        return;
    }
    OwlWindow *window = [wrapper window];
    if (window == nil) {
        return;
    }

    [window makeKeyAndOrderFront: nil];
    if (![NSApp isActive]) {
        [NSApp requestUserAttention: NSInformationalRequest];
    }
}

static const struct xdg_activation_v1_interface activation_impl = {
    .destroy = activation_destroy_handler,
    .get_activation_token = activation_get_activation_token_handler,
    .activate = activation_activate_handler
};

static void activation_destroy(struct wl_resource *resource) {
    OwlXdgActivationV1 *self = wl_resource_get_user_data(resource);
    [self release];
}

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &activation_impl,
        [self retain],
        activation_destroy
    );
    return self;
}

static void activation_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &xdg_activation_v1_interface,
        version,
        id
    );
    [[[OwlXdgActivationV1 alloc] initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    wl_global_create(
        display,
        &xdg_activation_v1_interface,
        1,
        NULL,
        activation_bind
    );
}

@end
