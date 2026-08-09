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

#import "OwlZwpPrimarySelectionDeviceV1.h"
#import "OwlZwpPrimarySelectionSourceV1.h"
#import "OwlZwpPrimarySelectionOfferV1.h"
#import "OwlSelection.h"
#import "primary-selection-unstable-v1.h"
#import <wayland-server.h>


@implementation OwlZwpPrimarySelectionDeviceV1

static NSMutableArray *primaryDevices;

+ (void) initialize {
    if (primaryDevices == nil) {
        primaryDevices = [[NSMutableArray alloc] initWithCapacity: 1];
    }
}

+ (OwlZwpPrimarySelectionDeviceV1 *) deviceForClient: (struct wl_client *) client {
    for (OwlZwpPrimarySelectionDeviceV1 *device in primaryDevices) {
        struct wl_resource *resource = device->_resource;
        if (client == wl_resource_get_client(resource)) {
            return device;
        }
    }
    return nil;
}

static void primary_selection_device_destroy(struct wl_resource *resource) {
    OwlZwpPrimarySelectionDeviceV1 *self = wl_resource_get_user_data(resource);
    [primaryDevices removeObjectIdenticalTo: self];
    [self release];
}

static void primary_selection_device_set_selection_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_resource *source_resource,
    uint32_t serial
) {
    // TODO: Check the serial corresponds to an event of the focused surface
    // and the event is not it gaining focus.
    OwlZwpPrimarySelectionSourceV1 *dataSource = nil;
    if (source_resource != NULL) {
        dataSource = wl_resource_get_user_data(source_resource);
    }
    [[OwlSelection primary] setDataSource: dataSource];
}

static void primary_selection_device_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static const struct zwp_primary_selection_device_v1_interface
primary_selection_device_impl = {
    .set_selection = primary_selection_device_set_selection_handler,
    .destroy = primary_selection_device_destroy_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    self = [super initWithResource: resource];
    wl_resource_set_implementation(
        resource,
        &primary_selection_device_impl,
        [self retain],
        primary_selection_device_destroy
    );
    [primaryDevices addObject: self];
    [[OwlSelection primary] addDataDevice: self];
    // FIXME: Call [self focused] here if we already have focus.
    [self selectionChanged: [OwlSelection primary]];
    return self;
}

- (void) dealloc {
    [[OwlSelection primary] removeDataDevice: self];
    [super dealloc];
}

- (void) sendSelection {
    _selectionHasChangedSinceLastFocused = NO;
    OwlDataSource *dataSource = [[OwlSelection primary] dataSource];

    if (dataSource == nil) {
        zwp_primary_selection_device_v1_send_selection(_resource, NULL);
        return;
    }

    struct wl_resource *offer_resource = wl_resource_create(
         wl_resource_get_client(_resource),
         &zwp_primary_selection_offer_v1_interface,
         wl_resource_get_version(_resource),
         0
    );
    zwp_primary_selection_device_v1_send_data_offer(_resource, offer_resource);
    // Creating the offer sends out the MIME types automatically.
    OwlZwpPrimarySelectionOfferV1 *offer =
        [[OwlZwpPrimarySelectionOfferV1 alloc] initWithResource: offer_resource
                                                      dataSource: dataSource];
    zwp_primary_selection_device_v1_send_selection(_resource, offer_resource);
    [offer release];
}

- (void) selectionChanged: (OwlSelection *) selection {
    if (_focusCount > 0) {
        [self sendSelection];
    } else {
        _selectionHasChangedSinceLastFocused = YES;
    }
}

- (void) focused {
    _focusCount++;
    if (_focusCount == 1 && _selectionHasChangedSinceLastFocused) {
        [self sendSelection];
    }
}

- (void) unfocused {
    _focusCount--;
}

@end
