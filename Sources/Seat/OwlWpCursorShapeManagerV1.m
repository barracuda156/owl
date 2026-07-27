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

#import "OwlWpCursorShapeManagerV1.h"
#import "OwlPointer.h"
#import "OwlFeatures.h"
#import "cursor-shape-v1.h"
#import <wayland-server.h>


/* The per-device object. _pointerResource is NULL for tablet tool
 * devices (which owl doesn't support) or once the backing wl_pointer
 * has been destroyed; set_shape becomes a no-op in that case. */
@interface OwlWpCursorShapeDeviceV1 : NSObject {
@public
    struct wl_resource *_resource;
    struct wl_resource *_pointerResource;
    struct wl_listener _pointerDestroyListener;
}

- (id) initWithResource: (struct wl_resource *) resource
        pointerResource: (struct wl_resource *) pointerResource;

@end

@implementation OwlWpCursorShapeDeviceV1

static NSMutableArray *devices;

+ (void) initialize {
    if (devices == nil) {
        devices = [[NSMutableArray alloc] initWithCapacity: 1];
    }
}

static void pointer_destroy_notify(struct wl_listener *listener, void *data) {
    OwlWpCursorShapeDeviceV1 *self = nil;
    for (OwlWpCursorShapeDeviceV1 *device in devices) {
        if (&device->_pointerDestroyListener == listener) {
            self = device;
            break;
        }
    }
    if (self == nil) {
        return;
    }

    self->_pointerResource = NULL;
    wl_list_remove(&self->_pointerDestroyListener.link);
    wl_list_init(&self->_pointerDestroyListener.link);
}

static NSCursor *cursorForShape(uint32_t shape) {
    switch (shape) {
    case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_POINTER:
        return [NSCursor pointingHandCursor];
    case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_TEXT:
    case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_VERTICAL_TEXT:
        return [NSCursor IBeamCursor];
    case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_CROSSHAIR:
        return [NSCursor crosshairCursor];
    case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_MOVE:
    case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ALL_SCROLL:
    case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_GRAB:
        return [NSCursor openHandCursor];
    case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_GRABBING:
        return [NSCursor closedHandCursor];
    case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_E_RESIZE:
        return [NSCursor resizeRightCursor];
    case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_W_RESIZE:
        return [NSCursor resizeLeftCursor];
    case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_N_RESIZE:
        return [NSCursor resizeUpCursor];
    case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_S_RESIZE:
        return [NSCursor resizeDownCursor];
    case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NS_RESIZE:
        return [NSCursor resizeUpDownCursor];
    case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_EW_RESIZE:
        return [NSCursor resizeLeftRightCursor];
#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1060
    case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ALIAS:
        return [NSCursor dragLinkCursor];
    case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_COPY:
        return [NSCursor dragCopyCursor];
    case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NO_DROP:
    case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NOT_ALLOWED:
        return [NSCursor operationNotAllowedCursor];
    case WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_CONTEXT_MENU:
        return [NSCursor contextualMenuCursor];
#endif
    // default, help, progress, wait, cell, zoom_in, zoom_out,
    // nesw_resize, nwse_resize, col_resize, row_resize, and (on
    // pre-10.6) alias/copy/no_drop/not_allowed/context_menu all
    // fall back to the plain arrow; macOS has no closer match.
    default:
        return [NSCursor arrowCursor];
    }
}

static void cursor_shape_device_destroy(struct wl_resource *resource) {
    OwlWpCursorShapeDeviceV1 *self = wl_resource_get_user_data(resource);
    [devices removeObjectIdenticalTo: self];
    [self release];
}

static void cursor_shape_device_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void cursor_shape_device_set_shape_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t serial,
    uint32_t shape
) {
    if (shape < WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT
        || shape > WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ZOOM_OUT) {
        wl_resource_post_error(
            resource,
            WP_CURSOR_SHAPE_DEVICE_V1_ERROR_INVALID_SHAPE,
            "invalid cursor shape %u",
            shape
        );
        return;
    }

    OwlWpCursorShapeDeviceV1 *self = wl_resource_get_user_data(resource);
    if (self->_pointerResource == NULL) {
        // No backing wl_pointer (a tablet tool device, or the
        // wl_pointer has since been destroyed): nothing to do.
        return;
    }

    OwlPointer *pointer = wl_resource_get_user_data(self->_pointerResource);
    [pointer setNamedCursor: cursorForShape(shape)];
}

static const struct wp_cursor_shape_device_v1_interface
cursor_shape_device_impl = {
    .destroy = cursor_shape_device_destroy_handler,
    .set_shape = cursor_shape_device_set_shape_handler
};

- (id) initWithResource: (struct wl_resource *) resource
        pointerResource: (struct wl_resource *) pointerResource
{
    _resource = resource;
    _pointerResource = pointerResource;
    wl_list_init(&_pointerDestroyListener.link);
    if (pointerResource != NULL) {
        _pointerDestroyListener.notify = pointer_destroy_notify;
        wl_resource_add_destroy_listener(
            pointerResource,
            &_pointerDestroyListener
        );
    }
    [devices addObject: self];

    wl_resource_set_implementation(
        resource,
        &cursor_shape_device_impl,
        [self retain],
        cursor_shape_device_destroy
    );

    return self;
}

- (void) dealloc {
    if (_pointerResource != NULL) {
        wl_list_remove(&_pointerDestroyListener.link);
    }
    [super dealloc];
}

@end


@implementation OwlWpCursorShapeManagerV1

static void cursor_shape_manager_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void cursor_shape_manager_get_pointer_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    struct wl_resource *pointer_resource
) {
    struct wl_resource *device_resource = wl_resource_create(
        client,
        &wp_cursor_shape_device_v1_interface,
        wl_resource_get_version(resource),
        id
    );
    OwlWpCursorShapeDeviceV1 *device = [OwlWpCursorShapeDeviceV1 alloc];
    [[device initWithResource: device_resource
              pointerResource: pointer_resource] release];
}

static void cursor_shape_manager_get_tablet_tool_v2_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    struct wl_resource *tablet_tool_resource
) {
    // Owl has no tablet support; create an inert device (no backing
    // pointer) so set_shape on it is simply a no-op.
    struct wl_resource *device_resource = wl_resource_create(
        client,
        &wp_cursor_shape_device_v1_interface,
        wl_resource_get_version(resource),
        id
    );
    OwlWpCursorShapeDeviceV1 *device = [OwlWpCursorShapeDeviceV1 alloc];
    [[device initWithResource: device_resource
              pointerResource: NULL] release];
}

static const struct wp_cursor_shape_manager_v1_interface
cursor_shape_manager_impl = {
    .destroy = cursor_shape_manager_destroy_handler,
    .get_pointer = cursor_shape_manager_get_pointer_handler,
    .get_tablet_tool_v2 = cursor_shape_manager_get_tablet_tool_v2_handler
};

static void cursor_shape_manager_destroy(struct wl_resource *resource) {
    OwlWpCursorShapeManagerV1 *self = wl_resource_get_user_data(resource);
    [self release];
}

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &cursor_shape_manager_impl,
        [self retain],
        cursor_shape_manager_destroy
    );
    return self;
}

static void cursor_shape_manager_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &wp_cursor_shape_manager_v1_interface,
        version,
        id
    );
    [[[OwlWpCursorShapeManagerV1 alloc] initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    wl_global_create(
        display,
        &wp_cursor_shape_manager_v1_interface,
        1,
        NULL,
        cursor_shape_manager_bind
    );
}

@end
