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

#import "OwlZwpPrimarySelectionSourceV1.h"
#import "primary-selection-unstable-v1.h"


@implementation OwlZwpPrimarySelectionSourceV1

static void primary_selection_source_destroy(struct wl_resource *resource) {
    OwlZwpPrimarySelectionSourceV1 *self = wl_resource_get_user_data(resource);
    [self releaseFromHolders];
    [self release];
}

static void primary_selection_source_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void primary_selection_source_offer_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    const char *mime_type
) {
    OwlZwpPrimarySelectionSourceV1 *self = wl_resource_get_user_data(resource);
    [self->_mimeTypes addObject: [NSString stringWithUTF8String: mime_type]];
}

static const struct zwp_primary_selection_source_v1_interface
primary_selection_source_impl = {
    .offer = primary_selection_source_offer_handler,
    .destroy = primary_selection_source_destroy_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    self = [super initWithResource: resource];
    wl_resource_set_implementation(
        resource,
        &primary_selection_source_impl,
        [self retain],
        primary_selection_source_destroy
    );
    return self;
}

- (void) sendContentOfMimeType: (NSString *) mimeType
                  toFileHandle: (NSFileHandle *) fileHandle
{
    zwp_primary_selection_source_v1_send_send(
        _resource,
        [mimeType UTF8String],
        [fileHandle fileDescriptor]
    );
}

- (void) sendCancelled {
    zwp_primary_selection_source_v1_send_cancelled(_resource);
}

@end
