/* This file is part of Owl.
 *
 * Copyright © 2026 Sergey Fedorov
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

/* The Mach half of the buffer handshake: looking up the compositor's
 * bootstrap port, retrieving per-IOSurface receiver ports with the
 * secret from the zowl_mach_ipc_port_v1.secret event, and handing the
 * compositor the IOSurface's Mach port. The MIG routines are
 * synchronous (they carry a reply), and the compositor serves them on
 * the same thread as its wayland event loop, so once a call returns,
 * any wayland request we send afterwards is processed after it.
 */

#include "owl-egl-private.h"

#include <stdio.h>
#include <servers/bootstrap.h>
#include <CoreFoundation/CoreFoundation.h>

#include "owl-mach-ipc-unstable-v1-mig.h"
#include "owl-iosurface-unstable-v1-mig.h"

IOSurfaceRef owl_egl_iosurface_create(int width, int height) {
    CFMutableDictionaryRef properties;
    CFNumberRef width_number, height_number;
    CFNumberRef bytes_per_element_number, bytes_per_row_number;
    CFNumberRef pixel_format_number;
    int bytes_per_element = 4;
    size_t bytes_per_row;
    /* The fourcc 'BGRA', matching what the compositor passes to
     * CGLTexImageIOSurface2D; both sides use identical format/type
     * parameters, so the pixel layout round-trips on both little-
     * and big-endian machines by construction. */
    uint32_t pixel_format =
        ((uint32_t) 'B' << 24) | ((uint32_t) 'G' << 16) |
        ((uint32_t) 'R' << 8) | (uint32_t) 'A';
    IOSurfaceRef iosurface;

    bytes_per_row = IOSurfaceAlignProperty(
        kIOSurfaceBytesPerRow,
        (size_t) width * bytes_per_element
    );

    properties = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        5,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    width_number = CFNumberCreate(
        kCFAllocatorDefault, kCFNumberIntType, &width);
    height_number = CFNumberCreate(
        kCFAllocatorDefault, kCFNumberIntType, &height);
    bytes_per_element_number = CFNumberCreate(
        kCFAllocatorDefault, kCFNumberIntType, &bytes_per_element);
    bytes_per_row_number = CFNumberCreate(
        kCFAllocatorDefault, kCFNumberLongType, &bytes_per_row);
    pixel_format_number = CFNumberCreate(
        kCFAllocatorDefault, kCFNumberSInt32Type, &pixel_format);

    CFDictionarySetValue(properties, kIOSurfaceWidth, width_number);
    CFDictionarySetValue(properties, kIOSurfaceHeight, height_number);
    CFDictionarySetValue(
        properties, kIOSurfaceBytesPerElement, bytes_per_element_number);
    CFDictionarySetValue(
        properties, kIOSurfaceBytesPerRow, bytes_per_row_number);
    CFDictionarySetValue(
        properties, kIOSurfacePixelFormat, pixel_format_number);

    iosurface = IOSurfaceCreate(properties);

    CFRelease(width_number);
    CFRelease(height_number);
    CFRelease(bytes_per_element_number);
    CFRelease(bytes_per_row_number);
    CFRelease(pixel_format_number);
    CFRelease(properties);

    return iosurface;
}

EGLBoolean owl_egl_mach_lookup_server(struct owl_egl_display *display) {
    kern_return_t kr;

    kr = bootstrap_look_up(
        bootstrap_port,
        display->bootstrap_name,
        &display->server_port
    );
    if (kr != KERN_SUCCESS) {
        fprintf(
            stderr,
            "owl-egl: bootstrap_look_up(%s) failed: %x\n",
            display->bootstrap_name, kr
        );
        return EGL_FALSE;
    }
    return EGL_TRUE;
}

EGLBoolean owl_egl_mach_retrieve_port(mach_port_t server_port,
                                      const char *secret,
                                      mach_port_t *port_out)
{
    kern_return_t kr;

    kr = owl_mach_ipc_v1_retrieve_port(server_port, secret, port_out);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "owl-egl: retrieve_port failed: %x\n", kr);
        return EGL_FALSE;
    }
    if (!MACH_PORT_VALID(*port_out)) {
        fprintf(stderr, "owl-egl: retrieve_port returned a dead port\n");
        return EGL_FALSE;
    }
    return EGL_TRUE;
}

EGLBoolean owl_egl_mach_set_surface_port(mach_port_t receiver_port,
                                         IOSurfaceRef iosurface)
{
    mach_port_t iosurface_port;
    kern_return_t kr;

    iosurface_port = IOSurfaceCreateMachPort(iosurface);
    if (!MACH_PORT_VALID(iosurface_port)) {
        fprintf(stderr, "owl-egl: IOSurfaceCreateMachPort failed\n");
        return EGL_FALSE;
    }

    kr = owl_iosurface_v1_set_surface_port(receiver_port, iosurface_port);
    /* The MIG call copies the send right; drop our own. */
    mach_port_deallocate(mach_task_self(), iosurface_port);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "owl-egl: set_surface_port failed: %x\n", kr);
        return EGL_FALSE;
    }
    return EGL_TRUE;
}
