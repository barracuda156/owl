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
#import "OwlSurface.h"
#import "OwlZxdgOutputV1.h"
#import "OwlFeatures.h"

/* One entry in the displayID -> wl_global registry. wl_global's own
 * handle has no way to recover the display ID it was created for, so
 * this pairing is kept alongside it for the hot-plug diff and for the
 * grace-delayed wl_global_destroy below. */
@interface OwlOutputGlobalEntry : NSObject {
@public
    uint32_t _displayID;
    struct wl_global *_global;
}

@end

@implementation OwlOutputGlobalEntry
@end


@implementation OwlOutput

// Every live OwlOutput (one per client bind), unretained; appended in
// -initWithResource:screen:displayID:, removed in output_destroy.
static NSMutableArray *liveOutputs;
// The displayID -> wl_global registry for every currently advertised
// (or grace-period-pending-destroy) output global.
static NSMutableArray *outputGlobals;
// The display this global was added to, so the hot-plug handler can
// create/remove globals on it later.
static struct wl_display *server_display;

+ (void) initialize {
    if (liveOutputs == nil) {
        liveOutputs = [[NSMutableArray alloc] initWithCapacity: 1];
    }
    if (outputGlobals == nil) {
        outputGlobals = [[NSMutableArray alloc] initWithCapacity: 1];
    }
}

static struct wl_global *global_for_display_id(uint32_t displayID) {
    for (OwlOutputGlobalEntry *entry in outputGlobals) {
        if (entry->_displayID == displayID) {
            return entry->_global;
        }
    }
    return NULL;
}

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
    [liveOutputs removeObjectIdenticalTo: self];
    [self release];
}

- (void) sendOutputInfo {
    uint32_t version = wl_resource_get_version(_resource);
    // _screen can be nil only via the output_bind race noted there
    // (a bind for a display ID that vanished between wl_global_remove
    // and the bind reaching us). Guard explicitly rather than
    // messaging nil for a struct return -- that reliably yields a
    // zeroed struct on some ABIs but not all (notably not guaranteed
    // on PPC, nor for structs large enough to use a hidden-pointer
    // return), and NSRect is exactly that kind of struct.
    NSRect frame = (_screen != nil) ? [_screen frame] : NSZeroRect;

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
        // Keyed by the stable display ID rather than the screen's
        // current index in [NSScreen screens]: an index would shift
        // (and so change this output's advertised name on every
        // refresh) whenever an unrelated, lower-numbered display is
        // unplugged, and would need its own nil guard for the same
        // output_bind race _screen is already guarded against above.
        char name[32];
        snprintf(name, sizeof(name), "screen-%u", (unsigned)_displayID);
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
              displayID: (uint32_t) displayID
{
    _resource = resource;
    _screen = [screen retain];
    _displayID = displayID;

    wl_resource_set_implementation(
        resource,
        &output_impl,
        [self retain],
        output_destroy
    );

    [liveOutputs addObject: self];
    [self sendOutputInfo];
    return self;
}

- (void) dealloc {
    [_screen release];
    [super dealloc];
}

- (NSScreen *) screen {
    return _screen;
}

- (struct wl_resource *) resource {
    return _resource;
}

- (struct wl_client *) client {
    return wl_resource_get_client(_resource);
}

- (uint32_t) displayID {
    return _displayID;
}

- (void) refresh {
    NSScreen *newScreen = [OwlOutput screenForDisplayID: _displayID];
    if (newScreen != nil && newScreen != _screen) {
        [newScreen retain];
        [_screen release];
        _screen = newScreen;
    }
    [self sendOutputInfo];
}

+ (void) refreshDisplayID: (uint32_t) displayID {
    for (OwlOutput *output in liveOutputs) {
        if (output->_displayID == displayID) {
            [output refresh];
        }
    }
}

+ (NSArray *) liveOutputsForClient: (struct wl_client *) client {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity: 1];
    for (OwlOutput *output in liveOutputs) {
        if (wl_resource_get_client(output->_resource) == client) {
            [result addObject: output];
        }
    }
    return result;
}

+ (uint32_t) displayIDForScreen: (NSScreen *) screen {
#ifdef OWL_PLATFORM_APPLE
    NSNumber *number = [[screen deviceDescription]
        objectForKey: @"NSScreenNumber"];
    // A screen without an NSScreenNumber shouldn't happen in
    // practice; fall back to the null display ID (0) rather than
    // crash on -unsignedIntValue against nil (which is actually safe
    // in Objective-C and returns 0 anyway, but be explicit).
    if (number == nil) {
        return 0;
    }
    return [number unsignedIntValue];
#else
    return (uint32_t) [[NSScreen screens] indexOfObject: screen];
#endif
}

+ (NSScreen *) screenForDisplayID: (uint32_t) displayID {
    NSArray *screens = [NSScreen screens];
    NSUInteger i, count = [screens count];

    for (i = 0; i < count; i++) {
        NSScreen *screen = [screens objectAtIndex: i];
        if ([OwlOutput displayIDForScreen: screen] == displayID) {
            return screen;
        }
    }
    return nil;
}

static void output_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id_
) {
    // data is the display ID, boxed straight into the pointer -- not
    // an NSScreen*. A retained NSScreen would go stale across a
    // hot-plug (AppKit hands out fresh NSScreen instances after some
    // display changes), so the live screen is always re-resolved by
    // display ID at bind time instead.
    uint32_t displayID = (uint32_t)(uintptr_t) data;
    NSScreen *screen = [OwlOutput screenForDisplayID: displayID];
    struct wl_resource *resource = wl_resource_create(
        client,
        &wl_output_interface,
        version,
        id_
    );
    [[[OwlOutput alloc] initWithResource: resource
                                   screen: screen
                                displayID: displayID] release];
}

+ (void) createGlobalForDisplayID: (uint32_t) displayID {
    if (global_for_display_id(displayID) != NULL) {
        return;
    }
    struct wl_global *global = wl_global_create(
        server_display,
        &wl_output_interface,
        4,  /* version 4 for name/description */
        (void *)(uintptr_t) displayID,
        output_bind
    );
    OwlOutputGlobalEntry *entry = [OwlOutputGlobalEntry new];
    entry->_displayID = displayID;
    entry->_global = global;
    [outputGlobals addObject: entry];
    [entry release];
}

+ (void) destroyGlobal: (NSValue *) globalValue {
    wl_global_destroy([globalValue pointerValue]);
}

+ (void) removeGlobalForDisplayID: (uint32_t) displayID {
    OwlOutputGlobalEntry *found = nil;
    for (OwlOutputGlobalEntry *entry in outputGlobals) {
        if (entry->_displayID == displayID) {
            found = entry;
            break;
        }
    }
    if (found == nil) {
        return;
    }
    // outputGlobals is this entry's only owner (created at refcount
    // 1, added to the array, then released back down to 1); removing
    // it from the array can deallocate it on the spot, so pull the
    // wl_global* out first rather than read found-> after the remove.
    struct wl_global *global = found->_global;
    [outputGlobals removeObjectIdenticalTo: found];

    // Stop advertising and refuse further binds immediately, but keep
    // the global itself alive a little longer: a client may have
    // already sent a bind request for it before seeing the removal,
    // and destroying the global out from under an in-flight bind is
    // the kind of race wl_global_remove()+delayed wl_global_destroy()
    // exists to avoid (libwayland >= 1.17).
    wl_global_remove(global);
    [self performSelector: @selector(destroyGlobal:)
                withObject: [NSValue valueWithPointer: global]
                afterDelay: 5.0];
}

+ (void) screenParametersChanged: (NSNotification *) notification {
    NSArray *screens = [NSScreen screens];
    NSMutableSet *currentIDs = [NSMutableSet setWithCapacity: [screens count]];
    NSUInteger i, count = [screens count];

    for (i = 0; i < count; i++) {
        NSScreen *screen = [screens objectAtIndex: i];
        uint32_t displayID = [OwlOutput displayIDForScreen: screen];
        [currentIDs addObject: [NSNumber numberWithUnsignedInt: displayID]];

        if (global_for_display_id(displayID) == NULL) {
            [OwlOutput createGlobalForDisplayID: displayID];
        } else {
            // A surviving display: geometry may or may not have
            // changed, but resending the burst is harmless (clients
            // just re-consume it) and there is no cheaper way to
            // tell without diffing every field ourselves.
            [OwlOutput refreshDisplayID: displayID];
            [OwlZxdgOutputV1 refreshDisplayID: displayID];
        }
    }

    // Any registered display ID no longer present in [NSScreen
    // screens] has vanished. Collect first, then remove -- the loop
    // above must not mutate outputGlobals while iterating it.
    NSMutableArray *vanishedIDs = [NSMutableArray arrayWithCapacity: 1];
    for (OwlOutputGlobalEntry *entry in outputGlobals) {
        NSNumber *number = [NSNumber numberWithUnsignedInt: entry->_displayID];
        if (![currentIDs containsObject: number]) {
            [vanishedIDs addObject: number];
        }
    }
    for (NSNumber *number in vanishedIDs) {
        [OwlOutput removeGlobalForDisplayID: [number unsignedIntValue]];
    }

    // A surface's screen (and thus display ID) can change here even
    // without any -windowDidChangeScreen: firing, e.g. when the
    // display a window was on gets unplugged and AppKit relocates
    // the window to another one.
    [OwlSurface updateOutputEnterLeaveForAllSurfaces];
}

static void subscribe_to_screen_parameter_changes(void) {
    static BOOL subscribed;
    if (subscribed) {
        return;
    }
    subscribed = YES;
    [[NSNotificationCenter defaultCenter]
        addObserver: [OwlOutput class]
           selector: @selector(screenParametersChanged:)
               name: NSApplicationDidChangeScreenParametersNotification
             object: nil];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    server_display = display;

    NSArray *screens = [NSScreen screens];
    NSUInteger i, count = [screens count];

    for (i = 0; i < count; i++) {
        NSScreen *screen = [screens objectAtIndex: i];
        [OwlOutput createGlobalForDisplayID: [OwlOutput displayIDForScreen: screen]];
    }

    subscribe_to_screen_parameter_changes();
}

@end
