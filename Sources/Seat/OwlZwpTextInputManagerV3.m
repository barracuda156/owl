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

#import "OwlZwpTextInputManagerV3.h"
#import "OwlSurface.h"
#import "OwlServer.h"
#import "text-input-unstable-v3.h"


/* The keyboard-focused surface, if it is one of ours. Computed
 * rather than cached so there is no pointer to go stale when a
 * surface disappears without a leave. */
static OwlSurface *focused_owl_surface(void) {
    NSResponder *responder = [[NSApp keyWindow] firstResponder];
    if ([responder isKindOfClass: [OwlSurface class]]) {
        return (OwlSurface *) responder;
    }
    return nil;
}

/* One zwp_text_input_v3. Not tied to any one surface: per the
 * protocol it follows the keyboard focus among the surfaces of the
 * client that created it. All of the client → compositor state is
 * double-buffered and applied on commit. */
@interface OwlZwpTextInput : NSObject {
@public
    struct wl_resource *_resource;
    // The number of commit requests received; echoed back in every
    // done event, per the protocol's serial rules.
    uint32_t _commitCount;

    // Pending (uncommitted) state.
    BOOL _pendingEnabled;
    BOOL _pendingCursorRectangleIsSet;
    NSRect _pendingCursorRectangle;
    NSString *_pendingSurroundingText;
    int32_t _pendingSurroundingCursor;
    int32_t _pendingSurroundingAnchor;
    uint32_t _pendingChangeCause;
    uint32_t _pendingContentHint;
    uint32_t _pendingContentPurpose;

    // Current (committed) state.
    BOOL _enabled;
    BOOL _cursorRectangleIsSet;
    NSRect _cursorRectangle;
    NSString *_surroundingText;
    int32_t _surroundingCursor;
    int32_t _surroundingAnchor;
    uint32_t _changeCause;
    uint32_t _contentHint;
    uint32_t _contentPurpose;
}

- (id) initWithResource: (struct wl_resource *) resource;

@end

@implementation OwlZwpTextInput

static NSMutableArray *textInputs;

+ (void) initialize {
    if (textInputs == nil) {
        textInputs = [[NSMutableArray alloc] initWithCapacity: 1];
    }
}

- (struct wl_client *) client {
    return wl_resource_get_client(_resource);
}

static void text_input_destroy(struct wl_resource *resource) {
    OwlZwpTextInput *self = wl_resource_get_user_data(resource);
    [textInputs removeObjectIdenticalTo: self];
    [self release];
}

static void text_input_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void text_input_enable_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    OwlZwpTextInput *self = wl_resource_get_user_data(resource);
    // Enabling resets all the pending state to its defaults.
    self->_pendingEnabled = YES;
    self->_pendingCursorRectangleIsSet = NO;
    [self->_pendingSurroundingText release];
    self->_pendingSurroundingText = nil;
    self->_pendingSurroundingCursor = 0;
    self->_pendingSurroundingAnchor = 0;
    self->_pendingChangeCause = ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_INPUT_METHOD;
    self->_pendingContentHint = 0;
    self->_pendingContentPurpose = 0;
}

static void text_input_disable_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    OwlZwpTextInput *self = wl_resource_get_user_data(resource);
    self->_pendingEnabled = NO;
}

static void text_input_set_surrounding_text_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    const char *text,
    int32_t cursor,
    int32_t anchor
) {
    OwlZwpTextInput *self = wl_resource_get_user_data(resource);
    NSString *string = [[NSString alloc] initWithUTF8String: text];
    [self->_pendingSurroundingText release];
    self->_pendingSurroundingText = string;
    self->_pendingSurroundingCursor = cursor;
    self->_pendingSurroundingAnchor = anchor;
}

static void text_input_set_text_change_cause_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t cause
) {
    OwlZwpTextInput *self = wl_resource_get_user_data(resource);
    self->_pendingChangeCause = cause;
}

static void text_input_set_content_type_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t hint,
    uint32_t purpose
) {
    OwlZwpTextInput *self = wl_resource_get_user_data(resource);
    self->_pendingContentHint = hint;
    self->_pendingContentPurpose = purpose;
}

static void text_input_set_cursor_rectangle_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height
) {
    OwlZwpTextInput *self = wl_resource_get_user_data(resource);
    self->_pendingCursorRectangleIsSet = YES;
    self->_pendingCursorRectangle = NSMakeRect(x, y, width, height);
}

static void text_input_commit_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    OwlZwpTextInput *self = wl_resource_get_user_data(resource);
    self->_commitCount++;

    BOOL wasEnabled = self->_enabled;

    self->_enabled = self->_pendingEnabled;
    self->_cursorRectangleIsSet = self->_pendingCursorRectangleIsSet;
    self->_cursorRectangle = self->_pendingCursorRectangle;
    NSString *surrounding = [self->_pendingSurroundingText retain];
    [self->_surroundingText release];
    self->_surroundingText = surrounding;
    self->_surroundingCursor = self->_pendingSurroundingCursor;
    self->_surroundingAnchor = self->_pendingSurroundingAnchor;
    self->_changeCause = self->_pendingChangeCause;
    self->_contentHint = self->_pendingContentHint;
    self->_contentPurpose = self->_pendingContentPurpose;

    if (wasEnabled && !self->_enabled) {
        // The widget lost text focus; abandon any composition in
        // progress so a stale preedit doesn't linger in the view.
        OwlSurface *surface = focused_owl_surface();
        if (surface != nil
            && wl_resource_get_client([surface resource]) == [self client]) {
            [surface clearMarkedText];
        }
    }
}

/* Version 2 additions (actions, input panels); owl offers the
 * global at version 1, but keep the dispatch table total. */
static void text_input_set_available_actions_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    struct wl_array *available_actions
) {
}

static void text_input_show_input_panel_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
}

static void text_input_hide_input_panel_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
}

static const struct zwp_text_input_v3_interface text_input_impl = {
    .destroy = text_input_destroy_handler,
    .enable = text_input_enable_handler,
    .disable = text_input_disable_handler,
    .set_surrounding_text = text_input_set_surrounding_text_handler,
    .set_text_change_cause = text_input_set_text_change_cause_handler,
    .set_content_type = text_input_set_content_type_handler,
    .set_cursor_rectangle = text_input_set_cursor_rectangle_handler,
    .commit = text_input_commit_handler,
    .set_available_actions = text_input_set_available_actions_handler,
    .show_input_panel = text_input_show_input_panel_handler,
    .hide_input_panel = text_input_hide_input_panel_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    _pendingChangeCause = ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_INPUT_METHOD;
    [textInputs addObject: self];

    wl_resource_set_implementation(
        resource,
        &text_input_impl,
        [self retain],
        text_input_destroy
    );

    return self;
}

- (void) dealloc {
    [_pendingSurroundingText release];
    [_surroundingText release];
    [super dealloc];
}

@end


@implementation OwlZwpTextInputManagerV3

+ (void) keyboardEnteredSurface: (OwlSurface *) surface {
    struct wl_resource *surfaceResource = [surface resource];
    struct wl_client *client = wl_resource_get_client(surfaceResource);
    for (OwlZwpTextInput *textInput in textInputs) {
        if ([textInput client] != client) {
            continue;
        }
        zwp_text_input_v3_send_enter(
            textInput->_resource,
            surfaceResource
        );
    }
    [[OwlServer sharedServer] flushClientsLater];
}

+ (void) keyboardLeftSurface: (OwlSurface *) surface {
    struct wl_resource *surfaceResource = [surface resource];
    struct wl_client *client = wl_resource_get_client(surfaceResource);
    [surface clearMarkedText];
    for (OwlZwpTextInput *textInput in textInputs) {
        if ([textInput client] != client) {
            continue;
        }
        zwp_text_input_v3_send_leave(
            textInput->_resource,
            surfaceResource
        );
    }
    [[OwlServer sharedServer] flushClientsLater];
}

+ (BOOL) hasEnabledTextInputForSurfaceResource:
    (struct wl_resource *) surfaceResource
{
    struct wl_client *client = wl_resource_get_client(surfaceResource);
    for (OwlZwpTextInput *textInput in textInputs) {
        if ([textInput client] == client && textInput->_enabled) {
            return YES;
        }
    }
    return NO;
}

+ (void) sendPreeditString: (NSString *) text
               cursorBegin: (int32_t) cursorBegin
                 cursorEnd: (int32_t) cursorEnd
        forSurfaceResource: (struct wl_resource *) surfaceResource
{
    struct wl_client *client = wl_resource_get_client(surfaceResource);
    const char *utf8 = [text UTF8String];
    for (OwlZwpTextInput *textInput in textInputs) {
        if ([textInput client] != client || !textInput->_enabled) {
            continue;
        }
        zwp_text_input_v3_send_preedit_string(
            textInput->_resource,
            utf8,
            cursorBegin,
            cursorEnd
        );
        zwp_text_input_v3_send_done(
            textInput->_resource,
            textInput->_commitCount
        );
    }
    [[OwlServer sharedServer] flushClientsLater];
}

+ (void) sendCommitString: (NSString *) text
       forSurfaceResource: (struct wl_resource *) surfaceResource
{
    struct wl_client *client = wl_resource_get_client(surfaceResource);
    const char *utf8 = [text UTF8String];
    for (OwlZwpTextInput *textInput in textInputs) {
        if ([textInput client] != client || !textInput->_enabled) {
            continue;
        }
        // No preedit_string before this done: the pending preedit
        // defaults to empty, so the done below also clears any
        // composition shown by the client.
        zwp_text_input_v3_send_commit_string(
            textInput->_resource,
            utf8
        );
        zwp_text_input_v3_send_done(
            textInput->_resource,
            textInput->_commitCount
        );
    }
    [[OwlServer sharedServer] flushClientsLater];
}

+ (BOOL) getCursorRectangle: (NSRect *) rect
         forSurfaceResource: (struct wl_resource *) surfaceResource
{
    struct wl_client *client = wl_resource_get_client(surfaceResource);
    for (OwlZwpTextInput *textInput in textInputs) {
        if ([textInput client] != client || !textInput->_enabled) {
            continue;
        }
        if (textInput->_cursorRectangleIsSet) {
            *rect = textInput->_cursorRectangle;
            return YES;
        }
    }
    return NO;
}

static void text_input_manager_destroy(struct wl_resource *resource) {
    OwlZwpTextInputManagerV3 *self = wl_resource_get_user_data(resource);
    [self release];
}

static void text_input_manager_destroy_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static void text_input_manager_get_text_input_handler(
    struct wl_client *client,
    struct wl_resource *resource,
    uint32_t id,
    struct wl_resource *seat_resource
) {
    struct wl_resource *text_input_resource = wl_resource_create(
        client,
        &zwp_text_input_v3_interface,
        wl_resource_get_version(resource),
        id
    );
    OwlZwpTextInput *textInput = [OwlZwpTextInput alloc];
    textInput = [textInput initWithResource: text_input_resource];

    // If this client's surface already has the keyboard focus, let
    // the new text input know right away; the natural enter was
    // sent before this object existed. (NULL rather than nil:
    // GCC's ObjC headers define nil as (id)0, which fails to parse
    // in functions whose id parameter shadows the id type.)
    OwlSurface *surface = focused_owl_surface();
    if (surface != NULL
        && wl_resource_get_client([surface resource]) == client) {
        zwp_text_input_v3_send_enter(
            text_input_resource,
            [surface resource]
        );
    }
    [textInput release];
}

static const struct zwp_text_input_manager_v3_interface
text_input_manager_impl = {
    .destroy = text_input_manager_destroy_handler,
    .get_text_input = text_input_manager_get_text_input_handler
};

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    wl_resource_set_implementation(
        resource,
        &text_input_manager_impl,
        [self retain],
        text_input_manager_destroy
    );
    return self;
}

static void text_input_manager_bind(
    struct wl_client *client,
    void *data,
    uint32_t version,
    uint32_t id
) {
    struct wl_resource *resource = wl_resource_create(
        client,
        &zwp_text_input_manager_v3_interface,
        version,
        id
    );
    OwlZwpTextInputManagerV3 *self = [OwlZwpTextInputManagerV3 alloc];
    [[self initWithResource: resource] release];
}

+ (void) addGlobalToDisplay: (struct wl_display *) display {
    // Version 1: the version 2 additions (actions, input panels)
    // have no Cocoa counterpart yet.
    wl_global_create(
        display,
        &zwp_text_input_manager_v3_interface,
        1,
        NULL,
        text_input_manager_bind
    );
}

@end
