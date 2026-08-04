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

/* owl-egl: client-side EGL over CGL + IOSurface for the owl compositor.
 *
 * Plain C (C99), no Objective-C and no blocks: this library must build
 * with FSF GCC targeting Mac OS X 10.6 (including big-endian PowerPC).
 * See HWGL.md at the repository root for the design.
 */

#ifndef OWL_EGL_PRIVATE_H
#define OWL_EGL_PRIVATE_H

#include <EGL/egl.h>
#include <EGL/eglext.h>

#include <wayland-client.h>
#include <wayland-egl-backend.h>

#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#ifndef GL_GLEXT_PROTOTYPES
#define GL_GLEXT_PROTOTYPES 1
#endif
#include <OpenGL/glext.h>
#include <IOSurface/IOSurface.h>
#include <mach/mach.h>
#include <pthread.h>

#include "owl-mach-ipc-unstable-v1-client-protocol.h"
#include "owl-iosurface-unstable-v1-client-protocol.h"

#ifndef EGL_PLATFORM_WAYLAND_KHR
#define EGL_PLATFORM_WAYLAND_KHR 0x31D8
#endif
#ifndef EGL_PLATFORM_WAYLAND_EXT
#define EGL_PLATFORM_WAYLAND_EXT 0x31D8
#endif

struct owl_egl_config {
    EGLint config_id;
    EGLint red_size;
    EGLint green_size;
    EGLint blue_size;
    EGLint alpha_size;
    EGLint depth_size;
    EGLint stencil_size;
};

struct owl_egl_display {
    struct wl_display *wl_display;

    /* All of our objects live on a private event queue so that we
     * never steal events from (or have events stolen by) the
     * application's own dispatching. */
    struct wl_event_queue *queue;
    struct wl_display *wrapped_display;
    struct wl_registry *registry;

    struct zowl_mach_ipc_v1 *mach_ipc;
    struct zowl_iosurface_manager_v1 *iosurface_manager;
    char *bootstrap_name;
    mach_port_t server_port;

    EGLBoolean initialized;
    struct owl_egl_display *next;
};

struct owl_egl_context {
    struct owl_egl_display *display;
    const struct owl_egl_config *config;
    CGLContextObj cgl;
    /* Extension availability, probed on first eglMakeCurrent. */
    int checked_extensions;
    int has_fbo;
    int has_texture_rectangle;
    int has_packed_depth_stencil;
};

struct owl_egl_surface;

struct owl_egl_buffer {
    struct owl_egl_surface *surface;
    IOSurfaceRef iosurface;
    struct zowl_iosurface_v1 *zowl_surface;
    struct wl_buffer *wl_buffer;
    int width;
    int height;
    /* Attached by a commit and not yet released by the compositor. */
    int busy;

    /* GL names live in a specific CGL context; recreated if the
     * surface is later used with a different context. */
    int has_gl;
    CGLContextObj gl_ctx;
    GLuint tex;
    GLuint fbo;
    GLuint depth_stencil;
};

#define OWL_EGL_BUFFER_COUNT 3

struct owl_egl_surface {
    struct owl_egl_display *display;
    const struct owl_egl_config *config;
    struct wl_egl_window *window;
    struct wl_surface *wl_surface;
    /* Wrapper proxy on our queue: wl_surface.frame callbacks created
     * from it inherit the queue; attach/damage/commit go through the
     * application's own proxy (requests carry no queue semantics). */
    struct wl_surface *wrapped_surface;

    struct owl_egl_buffer *buffers[OWL_EGL_BUFFER_COUNT];
    struct owl_egl_buffer *back;
    struct wl_callback *frame_callback;
    int swap_interval;
    /* Per EGL spec the viewport and scissor are initialized to the
     * surface size the first time a context is made current with it. */
    int viewport_initialized;
};

/* Per-thread EGL state. EGL's current context/surface and last error
 * are thread-local, which matches CGLSetCurrentContext being
 * per-thread. */
struct owl_egl_thread {
    EGLint error;
    EGLenum api;
    struct owl_egl_display *current_display;
    struct owl_egl_context *current_context;
    struct owl_egl_surface *current_surface;

    /* Framebuffer-zero remapping (egl-fbzero.c): the FBO name that
     * the client's "framebuffer 0" currently stands for, and whether
     * the client is logically bound to 0 right now. */
    GLuint zero_fbo;
    int app_at_zero;
};

/* egl-core.c */
struct owl_egl_thread *owl_egl_thread_state(void);
void owl_egl_set_error(EGLint error);
extern pthread_mutex_t owl_egl_lock;

/* egl-wayland.c */
EGLBoolean owl_egl_display_connect(struct owl_egl_display *display);
void owl_egl_display_disconnect(struct owl_egl_display *display);
struct owl_egl_buffer *owl_egl_surface_acquire_buffer(
    struct owl_egl_surface *surface);
EGLBoolean owl_egl_surface_swap(struct owl_egl_surface *surface);
void owl_egl_buffer_destroy(struct owl_egl_buffer *buffer);
void owl_egl_surface_destroy_buffers(struct owl_egl_surface *surface);
EGLBoolean owl_egl_buffer_ensure_gl(struct owl_egl_buffer *buffer,
                                    struct owl_egl_context *context);

/* egl-mach.c */
IOSurfaceRef owl_egl_iosurface_create(int width, int height);
EGLBoolean owl_egl_mach_lookup_server(struct owl_egl_display *display);
EGLBoolean owl_egl_mach_retrieve_port(mach_port_t server_port,
                                      const char *secret,
                                      mach_port_t *port_out);
EGLBoolean owl_egl_mach_set_surface_port(mach_port_t receiver_port,
                                         IOSurfaceRef iosurface);

/* egl-fbzero.c */
void *owl_egl_fbzero_lookup(const char *name);
void owl_egl_fbzero_make_current(GLuint fbo);
void owl_egl_fbzero_rebind(GLuint fbo);
GLuint owl_egl_fbzero_real_binding(void);
void owl_egl_fbzero_restore(GLuint fbo);

#endif /* OWL_EGL_PRIVATE_H */
