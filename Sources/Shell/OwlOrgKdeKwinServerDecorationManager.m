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

#import "OwlOrgKdeKwinServerDecorationManager.h"
#import "server-decoration.h"
#import <wayland-server.h>


@implementation OwlOrgKdeKwinServerDecorationManager

/* The per-surface decoration object. It has no state of its own:
 * whatever the client requests, the answer is always Server. */

static void decoration_release_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void decoration_request_mode_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t mode
) {
    // The protocol wants every request_mode acknowledged with a
    // mode event; the mode is always ours to pick, and it's Server.
    org_kde_kwin_server_decoration_send_mode(
        resource,
        ORG_KDE_KWIN_SERVER_DECORATION_MODE_SERVER
    );
}

static const struct org_kde_kwin_server_decoration_interface decoration_impl = {
    .release = decoration_release_handler,
    .request_mode = decoration_request_mode_handler
};

static void decoration_manager_create_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    struct wl_resource *surface_resource
) {
    struct wl_resource *decoration_resource = wl_resource_create(
        client,
        &org_kde_kwin_server_decoration_interface,
        wl_resource_get_version(resource),
        id
    );
    wl_resource_set_implementation(
        decoration_resource,
        &decoration_impl,
        NULL,
        NULL
    );

    // Announce the (only) decoration mode right away.
    org_kde_kwin_server_decoration_send_mode(
        decoration_resource,
        ORG_KDE_KWIN_SERVER_DECORATION_MODE_SERVER
    );
}

static const struct org_kde_kwin_server_decoration_manager_interface
decoration_manager_impl = {
    .create = decoration_manager_create_handler
};

static void decoration_manager_destroy(struct wl_resource *resource) {
    OwlOrgKdeKwinServerDecorationManager *self =
        wl_resource_get_user_data(resource);
    [self release];
}

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &decoration_manager_impl,
        [self retain],
        decoration_manager_destroy
    );

    // This is what makes GTK 3 pick server-side decorations: it
    // checks the default mode announced at bind time.
    org_kde_kwin_server_decoration_manager_send_default_mode(
        resource,
        ORG_KDE_KWIN_SERVER_DECORATION_MANAGER_MODE_SERVER
    );

    return self;
}

static void decoration_manager_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &org_kde_kwin_server_decoration_manager_interface,
        version,
        id
    );
    OwlOrgKdeKwinServerDecorationManager *manager =
        [OwlOrgKdeKwinServerDecorationManager alloc];
    [[manager initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    wl_global_create(
        display,
        &org_kde_kwin_server_decoration_manager_interface,
        1,
        NULL,
        decoration_manager_bind
    );
}

@end
