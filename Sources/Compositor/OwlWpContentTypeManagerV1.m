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

#import "OwlWpContentTypeManagerV1.h"
#import "content-type-v1.h"
#import <wayland-server.h>


/* Tracks which wl_surface resources already have a wp_content_type_v1
 * attached, so a second get_surface_content_type can be rejected. */
@interface OwlWpContentType : NSObject {
@public
    struct wl_resource *_resource;
    struct wl_resource *_surfaceResource;
    struct wl_listener _surfaceDestroyListener;
}

- (id) initWithResource: (struct wl_resource *) resource
         surfaceResource: (struct wl_resource *) surfaceResource;

@end

@implementation OwlWpContentType

static NSMutableArray *contentTypes;

+ (void) initialize {
    if (contentTypes == nil) {
        contentTypes = [[NSMutableArray alloc] initWithCapacity: 1];
    }
}

+ (BOOL) surfaceAlreadyHasContentType: (struct wl_resource *) surfaceResource {
    for (OwlWpContentType *contentType in contentTypes) {
        if (contentType->_surfaceResource == surfaceResource) {
            return YES;
        }
    }
    return NO;
}

static void surface_destroy_notify(struct wl_listener *listener, void *data) {
    OwlWpContentType *self = nil;
    for (OwlWpContentType *contentType in contentTypes) {
        if (&contentType->_surfaceDestroyListener == listener) {
            self = contentType;
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

static void content_type_destroy(struct wl_resource *resource) {
    OwlWpContentType *self = wl_resource_get_user_data(resource);
    [contentTypes removeObjectIdenticalTo: self];
    [self release];
}

static void content_type_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void content_type_set_content_type_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t content_type
) {
    // We have no content-type-specific rendering path; ignore the hint.
}

static const struct wp_content_type_v1_interface content_type_impl = {
    .destroy = content_type_destroy_handler,
    .set_content_type = content_type_set_content_type_handler
};

- (id) initWithResource: (struct wl_resource *) resource
         surfaceResource: (struct wl_resource *) surfaceResource
{
    _resource = resource;
    _surfaceResource = surfaceResource;
    _surfaceDestroyListener.notify = surface_destroy_notify;
    wl_resource_add_destroy_listener(
        surfaceResource,
        &_surfaceDestroyListener
    );
    [contentTypes addObject: self];

    wl_resource_set_implementation(
        resource,
        &content_type_impl,
        [self retain],
        content_type_destroy
    );

    return self;
}

- (void) dealloc {
    if (_surfaceResource != NULL) {
        wl_list_remove(&_surfaceDestroyListener.link);
    }
    [super dealloc];
}

@end


@implementation OwlWpContentTypeManagerV1

static void content_type_manager_destroy(struct wl_resource *resource) {
    OwlWpContentTypeManagerV1 *self = wl_resource_get_user_data(resource);
    [self release];
}

static void content_type_manager_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void content_type_manager_get_surface_content_type_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    struct wl_resource *surface_resource
) {
    if ([OwlWpContentType surfaceAlreadyHasContentType: surface_resource]) {
        wl_resource_post_error(
            resource,
            WP_CONTENT_TYPE_MANAGER_V1_ERROR_ALREADY_CONSTRUCTED,
            "wl_surface already has a wp_content_type_v1"
        );
        return;
    }

    struct wl_resource *content_type_resource = wl_resource_create(
        client,
        &wp_content_type_v1_interface,
        wl_resource_get_version(resource),
        id
    );
    OwlWpContentType *contentType = [OwlWpContentType alloc];
    [[contentType initWithResource: content_type_resource
                    surfaceResource: surface_resource] release];
}

static const struct wp_content_type_manager_v1_interface
content_type_manager_impl = {
    .destroy = content_type_manager_destroy_handler,
    .get_surface_content_type = content_type_manager_get_surface_content_type_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &content_type_manager_impl,
        [self retain],
        content_type_manager_destroy
    );
    return self;
}

static void content_type_manager_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &wp_content_type_manager_v1_interface,
        version,
        id
    );
    [[[OwlWpContentTypeManagerV1 alloc] initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    wl_global_create(
        display,
        &wp_content_type_manager_v1_interface,
        1,
        NULL,
        content_type_manager_bind
    );
}

@end
