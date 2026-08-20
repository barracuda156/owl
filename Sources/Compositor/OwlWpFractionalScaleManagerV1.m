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

#import "OwlWpFractionalScaleManagerV1.h"
#import "OwlSurface.h"
#import "OwlServer.h"
#import "OwlFeatures.h"
#import "fractional-scale-v1.h"


/* One wp_fractional_scale_v1, keyed to the wl_surface it extends. */
@interface OwlWpFractionalScale : NSObject {
@public
    struct wl_resource *_resource;
    struct wl_resource *_surfaceResource;
    struct wl_listener _surfaceDestroyListener;
    // The numerator (over a denominator of 120) we last told the
    // client, so that re-notifications only fire an event when the
    // scale actually changed. 0 means nothing was sent yet.
    uint32_t _sentScale;
}

- (id) initWithResource: (struct wl_resource *) resource
        surfaceResource: (struct wl_resource *) surfaceResource;

- (void) sendPreferredScale;

@end

@implementation OwlWpFractionalScale

static NSMutableArray *fractionalScales;

+ (void) initialize {
    if (fractionalScales == nil) {
        fractionalScales = [[NSMutableArray alloc] initWithCapacity: 1];
    }
}

+ (OwlWpFractionalScale *) fractionalScaleForSurfaceResource:
    (struct wl_resource *) surfaceResource
{
    for (OwlWpFractionalScale *fractionalScale in fractionalScales) {
        if (fractionalScale->_surfaceResource == surfaceResource) {
            return fractionalScale;
        }
    }
    return nil;
}

// The scale of the window (or, failing that, the screen) backing
// this surface, as the protocol's numerator over 120. backingScale-
// Factor only exists since 10.7; everywhere else the scale is 1.
static uint32_t preferred_scale_for_surface(OwlSurface *surface) {
    double scale = 1.0;
#if defined(OWL_PLATFORM_APPLE) && MAC_OS_X_VERSION_MAX_ALLOWED >= 1070
    NSWindow *window = [surface window];
    if (window != nil
        && [window respondsToSelector: @selector(backingScaleFactor)]) {
        scale = [window backingScaleFactor];
    } else {
        NSScreen *screen = [NSScreen mainScreen];
        if ([screen respondsToSelector: @selector(backingScaleFactor)]) {
            scale = [screen backingScaleFactor];
        }
    }
#endif
    return (uint32_t) (scale * 120.0 + 0.5);
}

- (void) sendPreferredScale {
    if (_surfaceResource == NULL) {
        return;
    }
    OwlSurface *surface = wl_resource_get_user_data(_surfaceResource);
    uint32_t scale = preferred_scale_for_surface(surface);
    if (scale == 0 || scale == _sentScale) {
        return;
    }
    _sentScale = scale;
    wp_fractional_scale_v1_send_preferred_scale(_resource, scale);
    [[OwlServer sharedServer] flushClientsLater];
}

static void fractional_scale_surface_destroy_notify(
    struct wl_listener *listener,
    void *data
) {
    OwlWpFractionalScale *self = nil;
    for (OwlWpFractionalScale *fractionalScale in fractionalScales) {
        if (&fractionalScale->_surfaceDestroyListener == listener) {
            self = fractionalScale;
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

static void fractional_scale_destroy(struct wl_resource *resource) {
    OwlWpFractionalScale *self = wl_resource_get_user_data(resource);
    [fractionalScales removeObjectIdenticalTo: self];
    [self release];
}

static void fractional_scale_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static const struct wp_fractional_scale_v1_interface fractional_scale_impl = {
    .destroy = fractional_scale_destroy_handler
};

- (id) initWithResource: (struct wl_resource *) resource
        surfaceResource: (struct wl_resource *) surfaceResource
{
    _resource = resource;
    _surfaceResource = surfaceResource;
    _surfaceDestroyListener.notify = fractional_scale_surface_destroy_notify;
    wl_resource_add_destroy_listener(
        surfaceResource,
        &_surfaceDestroyListener
    );
    [fractionalScales addObject: self];

    wl_resource_set_implementation(
        resource,
        &fractional_scale_impl,
        [self retain],
        fractional_scale_destroy
    );

    [self sendPreferredScale];

    return self;
}

- (void) dealloc {
    if (_surfaceResource != NULL) {
        wl_list_remove(&_surfaceDestroyListener.link);
    }
    [super dealloc];
}

@end


@implementation OwlWpFractionalScaleManagerV1

#if defined(OWL_PLATFORM_APPLE) && MAC_OS_X_VERSION_MAX_ALLOWED >= 1070
static void subscribeToBackingChanges(void) {
    static BOOL subscribed;
    if (subscribed) {
        return;
    }
    subscribed = YES;
    [[NSNotificationCenter defaultCenter]
        addObserver: [OwlWpFractionalScaleManagerV1 class]
           selector: @selector(windowChangedBackingProperties:)
               name: NSWindowDidChangeBackingPropertiesNotification
             object: nil];
}

+ (void) windowChangedBackingProperties: (NSNotification *) notification {
    NSWindow *window = [notification object];
    for (OwlWpFractionalScale *fractionalScale in fractionalScales) {
        if (fractionalScale->_surfaceResource == NULL) {
            continue;
        }
        OwlSurface *surface =
            wl_resource_get_user_data(fractionalScale->_surfaceResource);
        if ([surface window] == window) {
            [fractionalScale sendPreferredScale];
        }
    }
}
#else
static void subscribeToBackingChanges(void) {
}
#endif

+ (void) notifySurfaceMovedToWindow: (OwlSurface *) surface {
    OwlWpFractionalScale *fractionalScale = [OwlWpFractionalScale
        fractionalScaleForSurfaceResource: [surface resource]];
    [fractionalScale sendPreferredScale];
}

static void fractional_scale_manager_destroy(struct wl_resource *resource) {
    OwlWpFractionalScaleManagerV1 *self = wl_resource_get_user_data(resource);
    [self release];
}

static void fractional_scale_manager_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void fractional_scale_manager_get_fractional_scale_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    struct wl_resource *surface_resource
) {
    OwlWpFractionalScale *existing = [OwlWpFractionalScale
        fractionalScaleForSurfaceResource: surface_resource];
    // NULL rather than nil: GCC's ObjC headers define nil as (id)0,
    // which fails to parse in functions whose id parameter shadows
    // the id type, like this wayland request handler.
    if (existing != NULL) {
        wl_resource_post_error(
            resource,
            WP_FRACTIONAL_SCALE_MANAGER_V1_ERROR_FRACTIONAL_SCALE_EXISTS,
            "wl_surface@%u already has a wp_fractional_scale_v1",
            wl_resource_get_id(surface_resource)
        );
        return;
    }

    struct wl_resource *fractional_scale_resource = wl_resource_create(
        client,
        &wp_fractional_scale_v1_interface,
        wl_resource_get_version(resource),
        id
    );
    OwlWpFractionalScale *fractionalScale = [OwlWpFractionalScale alloc];
    [[fractionalScale initWithResource: fractional_scale_resource
                       surfaceResource: surface_resource] release];
}

static const struct wp_fractional_scale_manager_v1_interface
fractional_scale_manager_impl = {
    .destroy = fractional_scale_manager_destroy_handler,
    .get_fractional_scale = fractional_scale_manager_get_fractional_scale_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &fractional_scale_manager_impl,
        [self retain],
        fractional_scale_manager_destroy
    );
    return self;
}

static void fractional_scale_manager_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &wp_fractional_scale_manager_v1_interface,
        version,
        id
    );
    OwlWpFractionalScaleManagerV1 *self = [OwlWpFractionalScaleManagerV1 alloc];
    [[self initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    subscribeToBackingChanges();
    wl_global_create(
        display,
        &wp_fractional_scale_manager_v1_interface,
        1,
        NULL,
        fractional_scale_manager_bind
    );
}

@end
