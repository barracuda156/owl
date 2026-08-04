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

/* The wayland half of owl-egl: binding the zowl globals on a private
 * event queue, the per-surface buffer pool, and the swap path
 * (frame-callback throttling, attach/damage/commit, rotation).
 */

#include "owl-egl-private.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <OpenGL/CGLIOSurface.h>

#ifndef GL_TEXTURE_BINDING_RECTANGLE_ARB
#define GL_TEXTURE_BINDING_RECTANGLE_ARB 0x84F6
#endif
#ifndef GL_RENDERBUFFER_BINDING_EXT
#define GL_RENDERBUFFER_BINDING_EXT 0x8CA7
#endif
#ifndef GL_DEPTH24_STENCIL8_EXT
#define GL_DEPTH24_STENCIL8_EXT 0x88F0
#endif
#ifndef GL_DEPTH_COMPONENT24
#define GL_DEPTH_COMPONENT24 0x81A6
#endif

static void mach_ipc_bootstrap_name(void *data,
                                    struct zowl_mach_ipc_v1 *mach_ipc,
                                    const char *name)
{
    struct owl_egl_display *display = data;

    free(display->bootstrap_name);
    display->bootstrap_name = strdup(name);
}

static const struct zowl_mach_ipc_v1_listener mach_ipc_listener = {
    mach_ipc_bootstrap_name
};

static void registry_global(void *data,
                            struct wl_registry *registry,
                            uint32_t name,
                            const char *interface,
                            uint32_t version)
{
    struct owl_egl_display *display = data;

    if (strcmp(interface, zowl_mach_ipc_v1_interface.name) == 0) {
        display->mach_ipc = wl_registry_bind(
            registry, name, &zowl_mach_ipc_v1_interface, 1);
        zowl_mach_ipc_v1_add_listener(
            display->mach_ipc, &mach_ipc_listener, display);
    } else if (strcmp(
        interface, zowl_iosurface_manager_v1_interface.name) == 0)
    {
        display->iosurface_manager = wl_registry_bind(
            registry, name, &zowl_iosurface_manager_v1_interface, 1);
    }
}

static void registry_global_remove(void *data,
                                   struct wl_registry *registry,
                                   uint32_t name)
{
}

static const struct wl_registry_listener registry_listener = {
    registry_global,
    registry_global_remove
};

EGLBoolean owl_egl_display_connect(struct owl_egl_display *display) {
    display->queue = wl_display_create_queue(display->wl_display);
    if (display->queue == NULL) {
        return EGL_FALSE;
    }
    display->wrapped_display = wl_proxy_create_wrapper(display->wl_display);
    if (display->wrapped_display == NULL) {
        return EGL_FALSE;
    }
    wl_proxy_set_queue(
        (struct wl_proxy *) display->wrapped_display, display->queue);

    display->registry = wl_display_get_registry(display->wrapped_display);
    wl_registry_add_listener(display->registry, &registry_listener, display);

    /* First roundtrip delivers the globals (binding the mach IPC
     * global makes the server send bootstrap_name); the second
     * delivers events triggered by our binds. */
    if (wl_display_roundtrip_queue(display->wl_display, display->queue) < 0 ||
        wl_display_roundtrip_queue(display->wl_display, display->queue) < 0)
    {
        return EGL_FALSE;
    }

    if (display->mach_ipc == NULL ||
        display->iosurface_manager == NULL ||
        display->bootstrap_name == NULL)
    {
        fprintf(
            stderr,
            "owl-egl: compositor does not offer the owl IOSurface "
            "protocol; is this owl?\n"
        );
        return EGL_FALSE;
    }

    return owl_egl_mach_lookup_server(display);
}

void owl_egl_display_disconnect(struct owl_egl_display *display) {
    if (display->mach_ipc != NULL) {
        zowl_mach_ipc_v1_destroy(display->mach_ipc);
        display->mach_ipc = NULL;
    }
    if (display->iosurface_manager != NULL) {
        zowl_iosurface_manager_v1_destroy(display->iosurface_manager);
        display->iosurface_manager = NULL;
    }
    if (display->registry != NULL) {
        wl_registry_destroy(display->registry);
        display->registry = NULL;
    }
    if (display->wrapped_display != NULL) {
        wl_proxy_wrapper_destroy(display->wrapped_display);
        display->wrapped_display = NULL;
    }
    if (display->queue != NULL) {
        wl_event_queue_destroy(display->queue);
        display->queue = NULL;
    }
    free(display->bootstrap_name);
    display->bootstrap_name = NULL;
    if (MACH_PORT_VALID(display->server_port)) {
        mach_port_deallocate(mach_task_self(), display->server_port);
        display->server_port = MACH_PORT_NULL;
    }
}

struct secret_data {
    char *secret;
};

static void port_secret(void *data,
                        struct zowl_mach_ipc_port_v1 *port,
                        const char *secret)
{
    struct secret_data *secret_data = data;

    free(secret_data->secret);
    secret_data->secret = strdup(secret);
}

static const struct zowl_mach_ipc_port_v1_listener port_listener = {
    port_secret
};

static void buffer_release(void *data, struct wl_buffer *wl_buffer) {
    struct owl_egl_buffer *buffer = data;

    buffer->busy = 0;
}

static const struct wl_buffer_listener buffer_listener = {
    buffer_release
};

static struct owl_egl_buffer *owl_egl_buffer_create(
    struct owl_egl_surface *surface, int width, int height)
{
    struct owl_egl_display *display = surface->display;
    struct owl_egl_buffer *buffer;
    struct zowl_mach_ipc_port_v1 *port;
    struct secret_data secret_data = { NULL };
    mach_port_t receiver_port;

    buffer = calloc(1, sizeof *buffer);
    if (buffer == NULL) {
        return NULL;
    }
    buffer->surface = surface;
    buffer->width = width;
    buffer->height = height;

    buffer->iosurface = owl_egl_iosurface_create(width, height);
    if (buffer->iosurface == NULL) {
        fprintf(stderr, "owl-egl: IOSurfaceCreate(%dx%d) failed\n",
                width, height);
        free(buffer);
        return NULL;
    }

    /* See HWGL.md for the handshake. The port object and the
     * zowl_iosurface_v1 are created (asynchronously), then one
     * roundtrip guarantees the server has both the secret→port
     * mapping and the MIG receiver port before the synchronous MIG
     * calls below. */
    port = zowl_mach_ipc_v1_create_port(display->mach_ipc);
    zowl_mach_ipc_port_v1_add_listener(port, &port_listener, &secret_data);
    buffer->zowl_surface = zowl_iosurface_manager_v1_create_surface(
        display->iosurface_manager, port);

    if (wl_display_roundtrip_queue(display->wl_display, display->queue) < 0 ||
        secret_data.secret == NULL)
    {
        goto fail;
    }

    if (!owl_egl_mach_retrieve_port(
            display->server_port, secret_data.secret, &receiver_port))
    {
        goto fail;
    }
    free(secret_data.secret);
    secret_data.secret = NULL;

    if (!owl_egl_mach_set_surface_port(receiver_port, buffer->iosurface)) {
        mach_port_deallocate(mach_task_self(), receiver_port);
        goto fail;
    }
    mach_port_deallocate(mach_task_self(), receiver_port);

    buffer->wl_buffer = zowl_iosurface_v1_create_buffer(buffer->zowl_surface);
    wl_buffer_add_listener(buffer->wl_buffer, &buffer_listener, buffer);

    /* The port object's role has been played (the secret was consumed
     * by retrieve_port); the receiver port itself lives on in the
     * zowl_iosurface_v1. */
    zowl_mach_ipc_port_v1_destroy(port);

    return buffer;

fail:
    fprintf(stderr, "owl-egl: buffer handshake failed\n");
    free(secret_data.secret);
    zowl_mach_ipc_port_v1_destroy(port);
    if (buffer->zowl_surface != NULL) {
        zowl_iosurface_v1_destroy(buffer->zowl_surface);
    }
    CFRelease(buffer->iosurface);
    free(buffer);
    return NULL;
}

void owl_egl_buffer_destroy(struct owl_egl_buffer *buffer) {
    if (buffer->has_gl && buffer->gl_ctx == CGLGetCurrentContext()) {
        glDeleteTextures(1, &buffer->tex);
        glDeleteFramebuffersEXT(1, &buffer->fbo);
        if (buffer->depth_stencil != 0) {
            glDeleteRenderbuffersEXT(1, &buffer->depth_stencil);
        }
    }
    /* Otherwise the names die with their context. */
    if (buffer->wl_buffer != NULL) {
        wl_buffer_destroy(buffer->wl_buffer);
    }
    if (buffer->zowl_surface != NULL) {
        zowl_iosurface_v1_destroy(buffer->zowl_surface);
    }
    if (buffer->iosurface != NULL) {
        CFRelease(buffer->iosurface);
    }
    free(buffer);
}

void owl_egl_surface_destroy_buffers(struct owl_egl_surface *surface) {
    int i;

    for (i = 0; i < OWL_EGL_BUFFER_COUNT; i++) {
        if (surface->buffers[i] != NULL) {
            owl_egl_buffer_destroy(surface->buffers[i]);
            surface->buffers[i] = NULL;
        }
    }
    surface->back = NULL;
}

/* Find (or create) a non-busy buffer of the window's current size.
 * Buffers of a stale size are destroyed as they become free, which is
 * how resizes take effect. Blocks dispatching our queue if all
 * buffers are busy (the compositor releases the previous buffer when
 * the next commit replaces it). */
struct owl_egl_buffer *owl_egl_surface_acquire_buffer(
    struct owl_egl_surface *surface)
{
    struct owl_egl_display *display = surface->display;
    int width, height, i;

    if (surface->window == NULL) {
        return NULL;
    }
    width = surface->window->width;
    height = surface->window->height;
    if (width <= 0) {
        width = 1;
    }
    if (height <= 0) {
        height = 1;
    }

    wl_display_dispatch_queue_pending(display->wl_display, display->queue);

    for (;;) {
        struct owl_egl_buffer *buffer;
        int free_slot = -1;

        for (i = 0; i < OWL_EGL_BUFFER_COUNT; i++) {
            buffer = surface->buffers[i];
            if (buffer == NULL) {
                if (free_slot < 0) {
                    free_slot = i;
                }
                continue;
            }
            if (buffer->busy) {
                continue;
            }
            if (buffer->width != width || buffer->height != height) {
                owl_egl_buffer_destroy(buffer);
                surface->buffers[i] = NULL;
                if (free_slot < 0) {
                    free_slot = i;
                }
                continue;
            }
            return buffer;
        }

        if (free_slot >= 0) {
            buffer = owl_egl_buffer_create(surface, width, height);
            if (buffer == NULL) {
                return NULL;
            }
            surface->buffers[free_slot] = buffer;
            return buffer;
        }

        if (wl_display_dispatch_queue(
                display->wl_display, display->queue) < 0)
        {
            return NULL;
        }
    }
}

static void frame_done(void *data,
                       struct wl_callback *callback,
                       uint32_t time)
{
    struct owl_egl_surface *surface = data;

    wl_callback_destroy(callback);
    if (surface->frame_callback == callback) {
        surface->frame_callback = NULL;
    }
}

static const struct wl_callback_listener frame_listener = {
    frame_done
};

EGLBoolean owl_egl_surface_swap(struct owl_egl_surface *surface) {
    struct owl_egl_display *display = surface->display;
    struct owl_egl_buffer *buffer = surface->back;

    if (surface->window == NULL || buffer == NULL) {
        return EGL_FALSE;
    }

    wl_display_dispatch_queue_pending(display->wl_display, display->queue);

    if (surface->frame_callback != NULL) {
        if (surface->swap_interval > 0) {
            /* Throttle: wait for the previous frame's callback. */
            while (surface->frame_callback != NULL) {
                if (wl_display_dispatch_queue(
                        display->wl_display, display->queue) < 0)
                {
                    return EGL_FALSE;
                }
            }
        } else {
            /* Unthrottled: nobody will ever wait for it. */
            wl_callback_destroy(surface->frame_callback);
            surface->frame_callback = NULL;
        }
    }

    surface->frame_callback = wl_surface_frame(surface->wrapped_surface);
    wl_callback_add_listener(
        surface->frame_callback, &frame_listener, surface);

    wl_surface_attach(surface->wl_surface, buffer->wl_buffer, 0, 0);
    wl_surface_damage(
        surface->wl_surface, 0, 0, buffer->width, buffer->height);
    wl_surface_commit(surface->wl_surface);
    buffer->busy = 1;
    wl_display_flush(display->wl_display);

    surface->back = owl_egl_surface_acquire_buffer(surface);
    return surface->back != NULL ? EGL_TRUE : EGL_FALSE;
}

/* Create (or adopt) the GL names for this buffer in the given
 * context: an IOSurface-backed rectangle texture, an FBO with it as
 * the color attachment, and a depth/stencil renderbuffer if the
 * config asks for one. Restores the GL bindings it touches except
 * the framebuffer binding, which the caller is about to set anyway. */
EGLBoolean owl_egl_buffer_ensure_gl(struct owl_egl_buffer *buffer,
                                    struct owl_egl_context *context)
{
    GLint saved_tex, saved_rb;
    CGLError cgl_error;
    GLenum status;

    if (buffer->has_gl && buffer->gl_ctx == context->cgl) {
        return EGL_TRUE;
    }
    if (buffer->has_gl) {
        /* The names belong to a different context (surface moved
         * between contexts); they die with it. Just forget them. */
        buffer->has_gl = 0;
        buffer->depth_stencil = 0;
    }

    glGetIntegerv(GL_TEXTURE_BINDING_RECTANGLE_ARB, &saved_tex);
    glGetIntegerv(GL_RENDERBUFFER_BINDING_EXT, &saved_rb);

    glGenTextures(1, &buffer->tex);
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, buffer->tex);
    cgl_error = CGLTexImageIOSurface2D(
        context->cgl,
        GL_TEXTURE_RECTANGLE_ARB,
        GL_RGBA,
        buffer->width,
        buffer->height,
        GL_BGRA,
        GL_UNSIGNED_INT_8_8_8_8_REV,
        buffer->iosurface,
        0
    );
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, (GLuint) saved_tex);
    if (cgl_error != kCGLNoError) {
        fprintf(
            stderr,
            "owl-egl: CGLTexImageIOSurface2D failed: %s\n",
            CGLErrorString(cgl_error)
        );
        glDeleteTextures(1, &buffer->tex);
        return EGL_FALSE;
    }

    glGenFramebuffersEXT(1, &buffer->fbo);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, buffer->fbo);
    glFramebufferTexture2DEXT(
        GL_FRAMEBUFFER_EXT,
        GL_COLOR_ATTACHMENT0_EXT,
        GL_TEXTURE_RECTANGLE_ARB,
        buffer->tex,
        0
    );

    if (buffer->surface->config->depth_size > 0) {
        glGenRenderbuffersEXT(1, &buffer->depth_stencil);
        glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, buffer->depth_stencil);
        if (context->has_packed_depth_stencil) {
            glRenderbufferStorageEXT(
                GL_RENDERBUFFER_EXT,
                GL_DEPTH24_STENCIL8_EXT,
                buffer->width,
                buffer->height
            );
            glFramebufferRenderbufferEXT(
                GL_FRAMEBUFFER_EXT,
                GL_DEPTH_ATTACHMENT_EXT,
                GL_RENDERBUFFER_EXT,
                buffer->depth_stencil
            );
            glFramebufferRenderbufferEXT(
                GL_FRAMEBUFFER_EXT,
                GL_STENCIL_ATTACHMENT_EXT,
                GL_RENDERBUFFER_EXT,
                buffer->depth_stencil
            );
        } else {
            /* No packed depth/stencil on this renderer: depth only.
             * The configs still advertise stencil 8; accepted small
             * lie on museum GPUs (HWGL.md). */
            glRenderbufferStorageEXT(
                GL_RENDERBUFFER_EXT,
                GL_DEPTH_COMPONENT24,
                buffer->width,
                buffer->height
            );
            glFramebufferRenderbufferEXT(
                GL_FRAMEBUFFER_EXT,
                GL_DEPTH_ATTACHMENT_EXT,
                GL_RENDERBUFFER_EXT,
                buffer->depth_stencil
            );
        }
        glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, (GLuint) saved_rb);
    }

    status = glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT);
    if (status != GL_FRAMEBUFFER_COMPLETE_EXT) {
        fprintf(
            stderr,
            "owl-egl: framebuffer incomplete: 0x%x "
            "(rectangle textures not attachable on this renderer?)\n",
            status
        );
        glDeleteTextures(1, &buffer->tex);
        glDeleteFramebuffersEXT(1, &buffer->fbo);
        if (buffer->depth_stencil != 0) {
            glDeleteRenderbuffersEXT(1, &buffer->depth_stencil);
            buffer->depth_stencil = 0;
        }
        return EGL_FALSE;
    }

    buffer->has_gl = 1;
    buffer->gl_ctx = context->cgl;
    return EGL_TRUE;
}
