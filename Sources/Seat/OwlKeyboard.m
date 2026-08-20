/* This file is part of Owl.
 *
 * Copyright © 2019-2021 Sergey Bugaev <bugaevc@gmail.com>
 *
 * XKB keycode translation table adapted from Wawona:
 * Copyright © 2025 Alex Spaulding (MIT License)
 * https://github.com/Wawona/Wawona
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

#import "OwlKeyboard.h"
#import <fcntl.h>
#import <unistd.h>
#import "OwlServer.h"
#import "OwlSurface.h"
#import "OwlZwpTextInputManagerV3.h"
#import "OwlZwpKeyboardShortcutsInhibitManagerV1.h"
#import "OwlFeatures.h"

#ifdef OWL_PLATFORM_APPLE
    #import <Carbon/Carbon.h>
#endif

/* Modifier masks as laid out in our keymap.xkb
 * (the standard pc105 real-modifier assignment). */
#define OWL_MOD_SHIFT   1
#define OWL_MOD_LOCK    2
#define OWL_MOD_CONTROL 4
#define OWL_MOD_MOD1    8   /* Option/Alt */
#define OWL_MOD_MOD4    64  /* Command, when shortcuts are inhibited */

/* Evdev keycodes for (left) modifier keys. */
#define OWL_KEY_LEFTCTRL   29
#define OWL_KEY_LEFTSHIFT  42
#define OWL_KEY_LEFTALT    56
#define OWL_KEY_CAPSLOCK   58
#define OWL_KEY_LEFTMETA   125

/* Evdev keycodes bound to XF86Copy/XF86Paste in our keymap.xkb. */
#define OWL_KEY_COPY   133
#define OWL_KEY_PASTE  135

/* The keyboard repeat parameters we advertise to version 4+
 * clients; the clients implement the repeating themselves. */
#define OWL_KEY_REPEAT_RATE  25   /* keys per second */
#define OWL_KEY_REPEAT_DELAY 400  /* milliseconds */

@implementation OwlKeyboard

static NSMutableArray *keyboards;

/* The state of the physical modifiers. This is global rather
 * than per-client: there is only one physical keyboard, and we
 * need to replay its state to a client when its surface gains
 * keyboard focus. */
static uint32_t current_mods_depressed;
static uint32_t current_mods_locked;
static NSUInteger previous_cocoa_flags;

/* The evdev keycodes of the non-modifier keys whose press we have
 * forwarded to a client and whose release we haven't. Global for
 * the same reason the modifier state is: one physical keyboard. */
static NSMutableIndexSet *pressed_keys;

+ (void) initialize {
    if (keyboards == nil) {
        keyboards = [[NSMutableArray alloc] initWithCapacity: 1];
    }
    if (pressed_keys == nil) {
        pressed_keys = [[NSMutableIndexSet alloc] init];
    }
}

+ (OwlKeyboard *) keyboardForClient: (struct wl_client *) client {
    for (OwlKeyboard *keyboard in keyboards) {
        struct wl_resource *resource = keyboard->_resource;
        if (client == wl_resource_get_client(resource)) {
            return keyboard;
        }
    }
    return nil;
}

static void keyboard_destroy(struct wl_resource *resource) {
    OwlKeyboard *self = wl_resource_get_user_data(resource);
    [keyboards removeObjectIdenticalTo: self];
    [self release];
}

static void keyboard_release_handler(
    struct wl_client *client,
    struct wl_resource *resource
) {
    wl_resource_destroy(resource);
}

static const struct wl_keyboard_interface keyboard_impl = {
    .release = keyboard_release_handler
};

- (void) sendKeymap {
    NSString *path = [[NSBundle mainBundle] pathForResource: @"keymap"
                                                     ofType: @"xkb"];
    int fd = open([path fileSystemRepresentation], O_RDONLY);
    uint32_t len = lseek(fd, 0, SEEK_END);
    lseek(fd, 0, SEEK_SET);
    wl_keyboard_send_keymap(
        _resource,
        WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1,
        fd,
        len
    );
    close(fd);
}

- (id) initWithResource: (struct wl_resource *) resource {
    _resource = resource;
    [keyboards addObject: self];

    wl_resource_set_implementation(
        resource,
        &keyboard_impl,
        [self retain],
        keyboard_destroy
    );

    [self sendKeymap];

    if (wl_resource_get_version(resource) >= 4) {
        wl_keyboard_send_repeat_info(
            resource,
            OWL_KEY_REPEAT_RATE,
            OWL_KEY_REPEAT_DELAY
        );
    }

    return self;
}

- (struct wl_resource *) resource {
    return _resource;
}

#ifdef OWL_PLATFORM_APPLE

/* BEGIN: Adapted from Wawona (MIT License)
 * https://github.com/Wawona/Wawona/blob/master/src/platform/macos/WWNWindow.m
 * Copyright © 2025 Alex Spaulding
 *
 * Complete macOS → XKB/Evdev keycode translation table.
 */
static uint32_t MacosToXkbKeycode(unsigned short macCode) {
    switch (macCode) {
        /* Letters */
        case kVK_ANSI_A: return 30;
        case kVK_ANSI_B: return 48;
        case kVK_ANSI_C: return 46;
        case kVK_ANSI_D: return 32;
        case kVK_ANSI_E: return 18;
        case kVK_ANSI_F: return 33;
        case kVK_ANSI_G: return 34;
        case kVK_ANSI_H: return 35;
        case kVK_ANSI_I: return 23;
        case kVK_ANSI_J: return 36;
        case kVK_ANSI_K: return 37;
        case kVK_ANSI_L: return 38;
        case kVK_ANSI_M: return 50;
        case kVK_ANSI_N: return 49;
        case kVK_ANSI_O: return 24;
        case kVK_ANSI_P: return 25;
        case kVK_ANSI_Q: return 16;
        case kVK_ANSI_R: return 19;
        case kVK_ANSI_S: return 31;
        case kVK_ANSI_T: return 20;
        case kVK_ANSI_U: return 22;
        case kVK_ANSI_V: return 47;
        case kVK_ANSI_W: return 17;
        case kVK_ANSI_X: return 45;
        case kVK_ANSI_Y: return 21;
        case kVK_ANSI_Z: return 44;

        /* Numbers */
        case kVK_ANSI_1: return 2;
        case kVK_ANSI_2: return 3;
        case kVK_ANSI_3: return 4;
        case kVK_ANSI_4: return 5;
        case kVK_ANSI_5: return 6;
        case kVK_ANSI_6: return 7;
        case kVK_ANSI_7: return 8;
        case kVK_ANSI_8: return 9;
        case kVK_ANSI_9: return 10;
        case kVK_ANSI_0: return 11;

        /* Punctuation and symbols */
        case kVK_ANSI_Minus: return 12;
        case kVK_ANSI_Equal: return 13;
        case kVK_ANSI_LeftBracket: return 26;
        case kVK_ANSI_RightBracket: return 27;
        case kVK_ANSI_Backslash: return 43;
        case kVK_ANSI_Semicolon: return 39;
        case kVK_ANSI_Quote: return 40;
        case kVK_ANSI_Grave: return 41;
        case kVK_ANSI_Comma: return 51;
        case kVK_ANSI_Period: return 52;
        case kVK_ANSI_Slash: return 53;
        case kVK_ISO_Section: return 86; /* extra key on ISO keyboards */

        /* Special keys */
        case kVK_Return: return 28;
        case kVK_Tab: return 15;
        case kVK_Space: return 57;
        case kVK_Delete: return 14;             /* Backspace */
        case kVK_ForwardDelete: return 111;     /* Delete */
        case kVK_Escape: return 1;

        /* Modifier keys */
        case kVK_Shift: return OWL_KEY_LEFTSHIFT;
        case kVK_RightShift: return 54;
        case kVK_Control: return OWL_KEY_LEFTCTRL;
        case kVK_RightControl: return 97;
        case kVK_Option: return OWL_KEY_LEFTALT;
        case kVK_RightOption: return 100;
        case kVK_Command: return OWL_KEY_LEFTMETA;
        case 0x36: return 126;                  /* Right Command; no kVK_
                                                   constant in the 10.5 SDK */
        case kVK_CapsLock: return OWL_KEY_CAPSLOCK;

        /* Function keys */
        case kVK_F1: return 59;
        case kVK_F2: return 60;
        case kVK_F3: return 61;
        case kVK_F4: return 62;
        case kVK_F5: return 63;
        case kVK_F6: return 64;
        case kVK_F7: return 65;
        case kVK_F8: return 66;
        case kVK_F9: return 67;
        case kVK_F10: return 68;
        case kVK_F11: return 87;
        case kVK_F12: return 88;
        case kVK_F13: return 183;
        case kVK_F14: return 184;
        case kVK_F15: return 185;
        case kVK_F16: return 186;
        case kVK_F17: return 187;
        case kVK_F18: return 188;
        case kVK_F19: return 189;
        case kVK_F20: return 190;

        /* Arrow keys */
        case kVK_LeftArrow: return 105;
        case kVK_RightArrow: return 106;
        case kVK_UpArrow: return 103;
        case kVK_DownArrow: return 108;

        /* Navigation keys */
        case kVK_Home: return 102;
        case kVK_End: return 107;
        case kVK_PageUp: return 104;
        case kVK_PageDown: return 109;

        /* Keypad */
        case kVK_ANSI_KeypadDecimal: return 83;
        case kVK_ANSI_KeypadMultiply: return 55;
        case kVK_ANSI_KeypadPlus: return 78;
        case kVK_ANSI_KeypadClear: return 69;   /* Num Lock position */
        case kVK_ANSI_KeypadDivide: return 98;
        case kVK_ANSI_KeypadEnter: return 96;
        case kVK_ANSI_KeypadMinus: return 74;
        case kVK_ANSI_KeypadEquals: return 117;
        case kVK_ANSI_Keypad0: return 82;
        case kVK_ANSI_Keypad1: return 79;
        case kVK_ANSI_Keypad2: return 80;
        case kVK_ANSI_Keypad3: return 81;
        case kVK_ANSI_Keypad4: return 75;
        case kVK_ANSI_Keypad5: return 76;
        case kVK_ANSI_Keypad6: return 77;
        case kVK_ANSI_Keypad7: return 71;
        case kVK_ANSI_Keypad8: return 72;
        case kVK_ANSI_Keypad9: return 73;

        /* Media and system keys */
        case kVK_Help: return 138;
        case kVK_VolumeUp: return 115;
        case kVK_VolumeDown: return 114;
        case kVK_Mute: return 113;

        /* Unknown key */
        default: return 0;
    }
}
/* END: Wawona code */

- (uint32_t) xkbKeyCodeForCocoaKeyCode: (unsigned short) cocoaKeyCode {
    return MacosToXkbKeycode(cocoaKeyCode);
}

#else /* OWL_PLATFORM_APPLE */

- (uint32_t) xkbKeyCodeForCocoaKeyCode: (unsigned short) keyCode {
    static const struct {
        unsigned short from, to;
        uint32_t base;
    } translations[] = {
        {10, 22, 2},
        {24, 35, 16},
        {38, 48, 30},
        {52, 61, 44},
        {65, 65, 57},
        {36, 36, 28}
    };
    size_t translations_size = sizeof(translations) / sizeof(translations[0]);

    for (size_t i = 0; i < translations_size; i++) {
        if (keyCode >= translations[i].from && keyCode <= translations[i].to) {
            return keyCode - translations[i].from + translations[i].base;
        }
    }
    return keyCode;
}


#endif /* OWL_PLATFORM_APPLE */

- (void) sendKey: (unsigned short) keyCode isPressed: (BOOL) isPressed {
    enum wl_keyboard_key_state state = isPressed
        ? WL_KEYBOARD_KEY_STATE_PRESSED
        : WL_KEYBOARD_KEY_STATE_RELEASED;

    uint32_t xkbKeyCode = [self xkbKeyCodeForCocoaKeyCode: keyCode];
    if (xkbKeyCode == 0) {
        // We don't know how to translate this key; it's better
        // to say nothing than to send a bogus keycode.
        return;
    }

    if (isPressed) {
        [pressed_keys addIndex: xkbKeyCode];
    } else {
        if (![pressed_keys containsIndex: xkbKeyCode]) {
            // We never forwarded the press (a Command chord, or
            // it was force-released when Command engaged), so
            // don't send a spurious release.
            return;
        }
        [pressed_keys removeIndex: xkbKeyCode];
    }

    wl_keyboard_send_key(
        _resource,
        [[OwlServer sharedServer] nextSerial],
        [OwlServer timestamp],
        xkbKeyCode,
        state
    );
}

- (void) sendKeyRaw: (uint32_t) xkbKeyCode isPressed: (BOOL) isPressed {
    enum wl_keyboard_key_state state = isPressed
        ? WL_KEYBOARD_KEY_STATE_PRESSED
        : WL_KEYBOARD_KEY_STATE_RELEASED;

    wl_keyboard_send_key(
        _resource,
        [[OwlServer sharedServer] nextSerial],
        [OwlServer timestamp],
        xkbKeyCode,
        state
    );
}

- (void) releaseAllKeys {
    NSUInteger code = [pressed_keys firstIndex];
    while (code != NSNotFound) {
        [self sendKeyRaw: (uint32_t) code isPressed: NO];
        code = [pressed_keys indexGreaterThanIndex: code];
    }
    [pressed_keys removeAllIndexes];
}

- (void) sendModifiers: (uint32_t) modifiers {
    uint32_t serial = [[OwlServer sharedServer] nextSerial];
    wl_keyboard_send_modifiers(_resource, serial, modifiers, 0, 0, 0);
}

- (void) sendCurrentModifiers {
    uint32_t serial = [[OwlServer sharedServer] nextSerial];
    wl_keyboard_send_modifiers(
        _resource,
        serial,
        current_mods_depressed,
        0,
        current_mods_locked,
        0
    );
}

- (void) reconcileModifierFlags: (NSUInteger) flags
                 includeCommand: (BOOL) includeCommand
{
    // Command is deliberately absent from this table: it is the
    // compositor's modifier (menu shortcuts like Cmd+C/Cmd+V), so
    // clients normally never see it as Mod4 or as a Meta key press.
    // The exception is a surface holding a keyboard shortcuts
    // inhibitor, for which includeCommand is YES and Command is
    // reconciled separately below.
    static const struct {
        NSUInteger cocoaMask;
        uint32_t modMask;
        uint32_t evdevCode;
    } modifiers[] = {
        {NSShiftKeyMask, OWL_MOD_SHIFT, OWL_KEY_LEFTSHIFT},
        {NSControlKeyMask, OWL_MOD_CONTROL, OWL_KEY_LEFTCTRL},
        {NSAlternateKeyMask, OWL_MOD_MOD1, OWL_KEY_LEFTALT}
    };
    size_t modifiers_size = sizeof(modifiers) / sizeof(modifiers[0]);

    NSUInteger changed = flags ^ previous_cocoa_flags;
    BOOL modsChanged = NO;
    size_t i;

    // Whether the client should currently see Command held down as
    // Super/Mod4, vs. whether it does. These can disagree without
    // any flags change, e.g. when the keyboard focus moves between
    // an inhibited and a non-inhibited surface with Command held.
    BOOL commandDown = (flags & NSCommandKeyMask) ? YES : NO;
    BOOL commandForwarded =
        (current_mods_depressed & OWL_MOD_MOD4) ? YES : NO;
    BOOL forwardCommand = includeCommand && commandDown;

    if (changed == 0 && forwardCommand == commandForwarded) {
        return;
    }

    for (i = 0; i < modifiers_size; i++) {
        if (!(changed & modifiers[i].cocoaMask)) {
            continue;
        }
        BOOL isPressed = (flags & modifiers[i].cocoaMask) ? YES : NO;
        if (isPressed) {
            current_mods_depressed |= modifiers[i].modMask;
        } else {
            current_mods_depressed &= ~modifiers[i].modMask;
        }
        [self sendKeyRaw: modifiers[i].evdevCode isPressed: isPressed];
        modsChanged = YES;
    }

    if (changed & NSAlphaShiftKeyMask) {
        // Caps Lock is special: Cocoa reports the lock state, not
        // the key state, so fake a full press-release and toggle
        // the locked modifier.
        current_mods_locked ^= OWL_MOD_LOCK;
        [self sendKeyRaw: OWL_KEY_CAPSLOCK isPressed: YES];
        [self sendKeyRaw: OWL_KEY_CAPSLOCK isPressed: NO];
        modsChanged = YES;
    }

    if (forwardCommand != commandForwarded) {
        if (forwardCommand) {
            current_mods_depressed |= OWL_MOD_MOD4;
            [self sendKeyRaw: OWL_KEY_LEFTMETA isPressed: YES];
        } else {
            current_mods_depressed &= ~OWL_MOD_MOD4;
            [self sendKeyRaw: OWL_KEY_LEFTMETA isPressed: NO];
            // Cocoa does not deliver keyUp for keys released while
            // Command is held, so any chord keys we forwarded are
            // potentially stuck down in the client; release them.
            [self releaseAllKeys];
        }
        modsChanged = YES;
    }

    if (!includeCommand
        && (changed & NSCommandKeyMask) && commandDown) {
        // Command is engaging and belongs to the compositor. Cocoa
        // will not deliver keyUp for keys released while Command is
        // held, so release everything now rather than leave keys
        // stuck down (and autorepeating) in the client.
        [self releaseAllKeys];
    }

    previous_cocoa_flags = flags;

    if (modsChanged) {
        [self sendCurrentModifiers];
    }
}

- (void) reconcileModifierFlags: (NSUInteger) flags {
    [self reconcileModifierFlags: flags includeCommand: NO];
}

- (void) sendCopyKey {
    [self sendKeyRaw: OWL_KEY_COPY isPressed: YES];
    [self sendKeyRaw: OWL_KEY_COPY isPressed: NO];
}

- (void) sendPasteKey {
    [self sendKeyRaw: OWL_KEY_PASTE isPressed: YES];
    [self sendKeyRaw: OWL_KEY_PASTE isPressed: NO];
}

- (void) sendEnterSurface: (OwlSurface *) surface {
    uint32_t serial = [[OwlServer sharedServer] nextSerial];
    struct wl_array keys;
    wl_array_init(&keys);
    wl_keyboard_send_enter(_resource, serial, [surface resource], &keys);
    wl_array_release(&keys);

    // The protocol requires a modifiers event to follow enter. The
    // globally tracked state may contain Mod4 from Command being
    // forwarded to a shortcuts-inhibited surface; when the focus
    // lands on a surface without an inhibitor, mask it out — that
    // surface must not see the compositor's own modifier. (The
    // per-event reconcile catches up with the real state on the
    // next event either way.)
    uint32_t depressed = current_mods_depressed;
    if (![OwlZwpKeyboardShortcutsInhibitManagerV1
             shortcutsInhibitedForSurfaceResource: [surface resource]]) {
        depressed &= ~OWL_MOD_MOD4;
    }
    wl_keyboard_send_modifiers(
        _resource,
        [[OwlServer sharedServer] nextSerial],
        depressed,
        0,
        current_mods_locked,
        0
    );

    // Text inputs follow the keyboard focus.
    [OwlZwpTextInputManagerV3 keyboardEnteredSurface: surface];
}

- (void) sendLeaveSurface: (OwlSurface *) surface {
    uint32_t serial = [[OwlServer sharedServer] nextSerial];
    wl_keyboard_send_leave(_resource, serial, [surface resource]);

    [OwlZwpTextInputManagerV3 keyboardLeftSurface: surface];
}

@end
