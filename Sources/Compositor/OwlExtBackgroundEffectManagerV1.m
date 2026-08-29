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

#import "OwlExtBackgroundEffectManagerV1.h"
#import "OwlSurface.h"
#import "OwlRegion.h"
#import "OwlFeatures.h"
#import "ext-background-effect-v1.h"

#ifdef OWL_PLATFORM_APPLE
    #include <dlfcn.h>
#endif


#ifdef OWL_PLATFORM_APPLE
// The connection id is int-sized on the wire, not a pointer, despite
// CGS's own headers (where they exist) sometimes typedef'ing it as
// one -- match the actual ABI, not the type name.
typedef uint32_t OwlCGSConnectionID;
typedef OwlCGSConnectionID (*OwlCGSConnectionFunc)(void);
typedef int (*OwlCGSSetBlurFunc)(
    OwlCGSConnectionID cid,
    uint32_t wid,
    int radius
);

static OwlCGSConnectionFunc CGSConnectionFunc;
static OwlCGSSetBlurFunc CGSSetBlurFunc;
static BOOL triedResolveCGSBlurBackend = NO;

// Resolves the private CGS symbols on first use and caches the
// result (both the function pointers and whether resolution
// succeeded, since a repeat dlsym is wasted work either way). Both
// symbols missing -- or either one -- leaves the backend
// unavailable: the manager still binds, it just advertises no blur
// capability and every apply call below is a no-op.
static BOOL resolveCGSBlurBackend(void) {
    if (triedResolveCGSBlurBackend) {
        return CGSConnectionFunc != NULL && CGSSetBlurFunc != NULL;
    }
    triedResolveCGSBlurBackend = YES;

    // CGSMainConnectionID is the modern name; _CGSDefaultConnection
    // is the 10.5/10.6-era one it superseded.
    CGSConnectionFunc = (OwlCGSConnectionFunc)
        dlsym(RTLD_DEFAULT, "CGSMainConnectionID");
    if (CGSConnectionFunc == NULL) {
        CGSConnectionFunc = (OwlCGSConnectionFunc)
            dlsym(RTLD_DEFAULT, "_CGSDefaultConnection");
    }
    CGSSetBlurFunc = (OwlCGSSetBlurFunc)
        dlsym(RTLD_DEFAULT, "CGSSetWindowBackgroundBlurRadius");

    return CGSConnectionFunc != NULL && CGSSetBlurFunc != NULL;
}

// The protocol carries no radius of its own; this is owl's own
// policy choice of how strong a blur to apply when a surface asks
// for one at all.
#define OWL_BACKGROUND_BLUR_RADIUS 20
#endif


/* One ext_background_effect_surface_v1, keyed to the wl_surface it
 * requests blur for. */
@interface OwlExtBackgroundEffectSurfaceV1 : NSObject {
@public
    struct wl_resource *_resource;
    struct wl_resource *_surfaceResource;
    struct wl_listener _surfaceDestroyListener;
}

- (id) initWithResource: (struct wl_resource *) resource
        surfaceResource: (struct wl_resource *) surfaceResource;

@end

@implementation OwlExtBackgroundEffectSurfaceV1

static NSMutableArray *backgroundEffects;

+ (void) initialize {
    if (backgroundEffects == nil) {
        backgroundEffects = [[NSMutableArray alloc] initWithCapacity: 1];
    }
}

+ (OwlExtBackgroundEffectSurfaceV1 *) backgroundEffectForSurfaceResource:
    (struct wl_resource *) surfaceResource
{
    for (OwlExtBackgroundEffectSurfaceV1 *effect in backgroundEffects) {
        if (effect->_surfaceResource == surfaceResource) {
            return effect;
        }
    }
    return nil;
}

static void background_effect_surface_destroy_notify(
    struct wl_listener *listener,
    void *data
) {
    OwlExtBackgroundEffectSurfaceV1 *self = nil;
    for (OwlExtBackgroundEffectSurfaceV1 *effect in backgroundEffects) {
        if (&effect->_surfaceDestroyListener == listener) {
            self = effect;
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

static void background_effect_surface_destroy(struct wl_resource *resource) {
    OwlExtBackgroundEffectSurfaceV1 *self = wl_resource_get_user_data(resource);
    if (self->_surfaceResource != NULL) {
        // Destroying the object removes the effect on the next
        // commit, same as an explicit set_blur_region(NULL) --
        // double-buffered like the blur flag itself.
        OwlSurface *surface =
            wl_resource_get_user_data(self->_surfaceResource);
        [surface setPendingBlurEnabled: NO];
    }
    [backgroundEffects removeObjectIdenticalTo: self];
    [self release];
}

static void background_effect_surface_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void background_effect_surface_set_blur_region_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *region_resource
) {
    OwlExtBackgroundEffectSurfaceV1 *self = wl_resource_get_user_data(resource);
    if (self->_surfaceResource == NULL) {
        wl_resource_post_error(
            resource,
            EXT_BACKGROUND_EFFECT_SURFACE_V1_ERROR_SURFACE_DESTROYED,
            "set_blur_region on a ext_background_effect_surface_v1 "
            "whose wl_surface is gone"
        );
        return;
    }

    OwlSurface *surface = wl_resource_get_user_data(self->_surfaceResource);
    BOOL blur = NO;
    if (region_resource != NULL) {
        // Copy semantics per spec (the client may destroy the
        // wl_region right after this request), so snapshot now.
        // CGS blur is whole-window, not region-shaped, so the
        // region is reduced to a plain on/off: whether it could
        // ever contain a point at all. This is conservative in the
        // safe direction and visually faithful in practice -- CGS
        // background blur only shows through where the window is
        // already non-opaque, and owl makes ARGB content non-opaque
        // there, so the client's own buffer alpha already controls
        // *where* blur is visible at finer grain than any region
        // this protocol could carry.
        OwlRegion *region = wl_resource_get_user_data(region_resource);
        NSData *ops = [region opsSnapshot];
        blur = [OwlRegion opsCanEverContainPoints: ops];
    }
    [surface setPendingBlurEnabled: blur];
}

static const struct ext_background_effect_surface_v1_interface
background_effect_surface_impl = {
    .destroy = background_effect_surface_destroy_handler,
    .set_blur_region = background_effect_surface_set_blur_region_handler
};

- (id) initWithResource: (struct wl_resource *) resource
        surfaceResource: (struct wl_resource *) surfaceResource
{
    _resource = resource;
    _surfaceResource = surfaceResource;
    _surfaceDestroyListener.notify = background_effect_surface_destroy_notify;
    wl_resource_add_destroy_listener(
        surfaceResource,
        &_surfaceDestroyListener
    );
    [backgroundEffects addObject: self];

    wl_resource_set_implementation(
        resource,
        &background_effect_surface_impl,
        [self retain],
        background_effect_surface_destroy
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


@implementation OwlExtBackgroundEffectManagerV1

static void background_effect_manager_destroy(struct wl_resource *resource) {
    OwlExtBackgroundEffectManagerV1 *self = wl_resource_get_user_data(resource);
    [self release];
}

static void background_effect_manager_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void background_effect_manager_get_background_effect_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id_,
    struct wl_resource *surface_resource
) {
    // NULL rather than nil: GCC's ObjC headers define nil as (id)0,
    // which fails to parse in functions whose id parameter shadows
    // the id type, like this wayland request handler.
    OwlExtBackgroundEffectSurfaceV1 *existing = [OwlExtBackgroundEffectSurfaceV1
        backgroundEffectForSurfaceResource: surface_resource];
    if (existing != NULL) {
        wl_resource_post_error(
            resource,
            EXT_BACKGROUND_EFFECT_MANAGER_V1_ERROR_BACKGROUND_EFFECT_EXISTS,
            "wl_surface@%u already has a ext_background_effect_surface_v1",
            wl_resource_get_id(surface_resource)
        );
        return;
    }

    struct wl_resource *effect_resource = wl_resource_create(
        client,
        &ext_background_effect_surface_v1_interface,
        wl_resource_get_version(resource),
        id_
    );
    OwlExtBackgroundEffectSurfaceV1 *effect =
        [OwlExtBackgroundEffectSurfaceV1 alloc];
    [[effect initWithResource: effect_resource
               surfaceResource: surface_resource] release];
}

static const struct ext_background_effect_manager_v1_interface
background_effect_manager_impl = {
    .destroy = background_effect_manager_destroy_handler,
    .get_background_effect = background_effect_manager_get_background_effect_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &background_effect_manager_impl,
        [self retain],
        background_effect_manager_destroy
    );

    // Sent once, right when the global is bound, per spec. Owl's
    // backend availability is a fixed fact of the running process
    // (either the private symbols resolved at first use or they
    // didn't), so unlike some other capability-style events there
    // is nothing to re-send later.
    uint32_t capabilities = 0;
#ifdef OWL_PLATFORM_APPLE
    if (resolveCGSBlurBackend()) {
        capabilities = EXT_BACKGROUND_EFFECT_MANAGER_V1_CAPABILITY_BLUR;
    }
#endif
    ext_background_effect_manager_v1_send_capabilities(resource, capabilities);

    return self;
}

static void background_effect_manager_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id_
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &ext_background_effect_manager_v1_interface,
        version,
        id_
    );
    [[[OwlExtBackgroundEffectManagerV1 alloc] initWithResource: resource]
        release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    wl_global_create(
        display,
        &ext_background_effect_manager_v1_interface,
        1,
        NULL,
        background_effect_manager_bind
    );
}

+ (void) applyBlur: (BOOL) enabled toWindow: (NSWindow *) window {
#ifdef OWL_PLATFORM_APPLE
    if (window == nil) {
        // No window yet; -[OwlSurface viewDidMoveToWindow] retries
        // this once there is one.
        return;
    }
    if (!resolveCGSBlurBackend()) {
        return;
    }
    OwlCGSConnectionID cid = CGSConnectionFunc();
    CGSSetBlurFunc(
        cid,
        (uint32_t) [window windowNumber],
        enabled ? OWL_BACKGROUND_BLUR_RADIUS : 0
    );
#endif
}

@end
