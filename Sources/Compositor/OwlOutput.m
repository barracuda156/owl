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

#import "OwlOutput.h"
#import "OwlFeatures.h"

@implementation OwlOutput

static void output_release_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static const struct wl_output_interface output_impl = {
    .release = output_release_handler
};

static void output_destroy(struct wl_resource *resource) {
    OwlOutput *self = wl_resource_get_user_data(resource);
    [self release];
}

- (void) sendOutputInfo {
    uint32_t version = wl_resource_get_version(_resource);
    NSRect frame = [_screen frame];

    /* Send geometry event */
    /* Physical size in mm - estimate based on 96 DPI if unknown */
    int32_t physical_width = (int32_t)(frame.size.width * 25.4 / 96.0);
    int32_t physical_height = (int32_t)(frame.size.height * 25.4 / 96.0);

    wl_output_send_geometry(
        _resource,
        (int32_t)frame.origin.x,    /* x */
        (int32_t)frame.origin.y,    /* y */
        physical_width,              /* physical_width in mm */
        physical_height,             /* physical_height in mm */
        WL_OUTPUT_SUBPIXEL_UNKNOWN,  /* subpixel */
        "Apple",                     /* make */
        "Display",                   /* model */
        WL_OUTPUT_TRANSFORM_NORMAL   /* transform */
    );

    /* Send mode event */
    wl_output_send_mode(
        _resource,
        WL_OUTPUT_MODE_CURRENT | WL_OUTPUT_MODE_PREFERRED,
        (int32_t)frame.size.width,
        (int32_t)frame.size.height,
        60000  /* refresh rate in mHz (60 Hz) */
    );

    /* Send scale event (version 2+) */
    if (version >= 2) {
        int32_t scale = 1;
#ifdef OWL_PLATFORM_APPLE
        /* backingScaleFactor available on 10.7+, use userSpaceScaleFactor on older */
#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1070
        if ([_screen respondsToSelector: @selector(backingScaleFactor)]) {
            scale = (int32_t)[_screen backingScaleFactor];
        }
#endif
#endif
        wl_output_send_scale(_resource, scale);
    }

    /* Send name event (version 4+) */
    if (version >= 4) {
        NSArray *screens = [NSScreen screens];
        NSUInteger index = [screens indexOfObject: _screen];
        char name[32];
        snprintf(name, sizeof(name), "screen-%lu", (unsigned long)index);
        wl_output_send_name(_resource, name);
    }

    /* Send description event (version 4+) */
    if (version >= 4) {
#ifdef OWL_PLATFORM_APPLE
        NSString *desc = nil;
#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1070
        if ([_screen respondsToSelector: @selector(localizedName)]) {
            desc = [_screen localizedName];
        }
#endif
        if (desc == nil) {
            desc = @"Display";
        }
        wl_output_send_description(_resource, [desc UTF8String]);
#else
        wl_output_send_description(_resource, "Display");
#endif
    }

    /* Send done event (version 2+) */
    if (version >= 2) {
        wl_output_send_done(_resource);
    }
}

- (id) initWithResource: (struct wl_resource *) resource
                 screen: (NSScreen *) screen
{
    _resource = resource;
    _screen = [screen retain];

    wl_resource_set_implementation(
        resource,
        &output_impl,
        [self retain],
        output_destroy
    );

    [self sendOutputInfo];
    return self;
}

- (void) dealloc {
    [_screen release];
    [super dealloc];
}

static void output_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    NSScreen *screen = (NSScreen *)data;
    struct wl_resource *resource = wl_resource_create(
        client,
        &wl_output_interface,
        version,
        id
    );
    [[[OwlOutput alloc] initWithResource: resource screen: screen] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    NSArray *screens = [NSScreen screens];
    NSUInteger i, count = [screens count];

    for (i = 0; i < count; i++) {
        NSScreen *screen = [screens objectAtIndex: i];
        // The global (and thus the bind callback's user data)
        // lives for as long as the display does, so keep the
        // screen object alive too.
        wl_global_create(
            display,
            &wl_output_interface,
            4,  /* version 4 for name/description */
            [screen retain],
            output_bind
        );
    }
}

@end
