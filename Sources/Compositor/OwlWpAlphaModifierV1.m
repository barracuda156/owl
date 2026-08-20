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

#import "OwlWpAlphaModifierV1.h"
#import "OwlSurface.h"
#import "alpha-modifier-v1.h"


/* One wp_alpha_modifier_surface_v1, keyed to the wl_surface whose
 * alpha it multiplies. */
@interface OwlWpAlphaModifierSurface : NSObject {
@public
    struct wl_resource *_resource;
    struct wl_resource *_surfaceResource;
    struct wl_listener _surfaceDestroyListener;
}

- (id) initWithResource: (struct wl_resource *) resource
        surfaceResource: (struct wl_resource *) surfaceResource;

@end

@implementation OwlWpAlphaModifierSurface

static NSMutableArray *alphaModifiers;

+ (void) initialize {
    if (alphaModifiers == nil) {
        alphaModifiers = [[NSMutableArray alloc] initWithCapacity: 1];
    }
}

+ (OwlWpAlphaModifierSurface *) alphaModifierForSurfaceResource:
    (struct wl_resource *) surfaceResource
{
    for (OwlWpAlphaModifierSurface *alphaModifier in alphaModifiers) {
        if (alphaModifier->_surfaceResource == surfaceResource) {
            return alphaModifier;
        }
    }
    return nil;
}

static void alpha_modifier_surface_destroy_notify(
    struct wl_listener *listener,
    void *data
) {
    OwlWpAlphaModifierSurface *self = nil;
    for (OwlWpAlphaModifierSurface *alphaModifier in alphaModifiers) {
        if (&alphaModifier->_surfaceDestroyListener == listener) {
            self = alphaModifier;
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

static void alpha_modifier_surface_destroy(struct wl_resource *resource) {
    OwlWpAlphaModifierSurface *self = wl_resource_get_user_data(resource);
    if (self->_surfaceResource != NULL) {
        // Destroying the object returns the surface to full
        // opacity, double-buffered like the multiplier itself.
        OwlSurface *surface =
            wl_resource_get_user_data(self->_surfaceResource);
        [surface setPendingAlphaMultiplier: 1.0];
    }
    [alphaModifiers removeObjectIdenticalTo: self];
    [self release];
}

static void alpha_modifier_surface_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void alpha_modifier_surface_set_multiplier_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t factor
) {
    OwlWpAlphaModifierSurface *self = wl_resource_get_user_data(resource);
    if (self->_surfaceResource == NULL) {
        wl_resource_post_error(
            resource,
            WP_ALPHA_MODIFIER_SURFACE_V1_ERROR_NO_SURFACE,
            "set_multiplier on a wp_alpha_modifier_surface_v1 "
            "whose wl_surface is gone"
        );
        return;
    }
    OwlSurface *surface = wl_resource_get_user_data(self->_surfaceResource);
    [surface setPendingAlphaMultiplier: (double) factor / (double) UINT32_MAX];
}

static const struct wp_alpha_modifier_surface_v1_interface
alpha_modifier_surface_impl = {
    .destroy = alpha_modifier_surface_destroy_handler,
    .set_multiplier = alpha_modifier_surface_set_multiplier_handler
};

- (id) initWithResource: (struct wl_resource *) resource
        surfaceResource: (struct wl_resource *) surfaceResource
{
    _resource = resource;
    _surfaceResource = surfaceResource;
    _surfaceDestroyListener.notify = alpha_modifier_surface_destroy_notify;
    wl_resource_add_destroy_listener(
        surfaceResource,
        &_surfaceDestroyListener
    );
    [alphaModifiers addObject: self];

    wl_resource_set_implementation(
        resource,
        &alpha_modifier_surface_impl,
        [self retain],
        alpha_modifier_surface_destroy
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


@implementation OwlWpAlphaModifierV1

static void alpha_modifier_destroy(struct wl_resource *resource) {
    OwlWpAlphaModifierV1 *self = wl_resource_get_user_data(resource);
    [self release];
}

static void alpha_modifier_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void alpha_modifier_get_surface_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    struct wl_resource *surface_resource
) {
    OwlWpAlphaModifierSurface *existing = [OwlWpAlphaModifierSurface
        alphaModifierForSurfaceResource: surface_resource];
    // NULL rather than nil: GCC's ObjC headers define nil as (id)0,
    // which fails to parse in functions whose id parameter shadows
    // the id type, like this wayland request handler.
    if (existing != NULL) {
        wl_resource_post_error(
            resource,
            WP_ALPHA_MODIFIER_V1_ERROR_ALREADY_CONSTRUCTED,
            "wl_surface@%u already has a wp_alpha_modifier_surface_v1",
            wl_resource_get_id(surface_resource)
        );
        return;
    }

    struct wl_resource *alpha_modifier_resource = wl_resource_create(
        client,
        &wp_alpha_modifier_surface_v1_interface,
        wl_resource_get_version(resource),
        id
    );
    OwlWpAlphaModifierSurface *alphaModifier =
        [OwlWpAlphaModifierSurface alloc];
    [[alphaModifier initWithResource: alpha_modifier_resource
                     surfaceResource: surface_resource] release];
}

static const struct wp_alpha_modifier_v1_interface alpha_modifier_impl = {
    .destroy = alpha_modifier_destroy_handler,
    .get_surface = alpha_modifier_get_surface_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &alpha_modifier_impl,
        [self retain],
        alpha_modifier_destroy
    );
    return self;
}

static void alpha_modifier_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &wp_alpha_modifier_v1_interface,
        version,
        id
    );
    [[[OwlWpAlphaModifierV1 alloc] initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    wl_global_create(
        display,
        &wp_alpha_modifier_v1_interface,
        1,
        NULL,
        alpha_modifier_bind
    );
}

@end
