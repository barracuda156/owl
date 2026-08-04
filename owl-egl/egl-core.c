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

/* The EGL entry points. EGL 1.4, OpenGL (desktop) API only, window
 * surfaces only, wayland platform only. EGL 1.5 entry points exist as
 * failing stubs so that binaries linked against a full EGL 1.5
 * library (Mesa) still load with this one substituted via
 * DYLD_LIBRARY_PATH.
 */

#include "owl-egl-private.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>

#define OWL_EGL_VERSION_MAJOR 1
#define OWL_EGL_VERSION_MINOR 4

/* ---------- Per-thread state ---------- */

pthread_mutex_t owl_egl_lock = PTHREAD_MUTEX_INITIALIZER;

static pthread_key_t thread_state_key;
static pthread_once_t thread_state_once = PTHREAD_ONCE_INIT;

static void thread_state_destroy(void *state) {
    free(state);
}

static void thread_state_init(void) {
    pthread_key_create(&thread_state_key, thread_state_destroy);
}

struct owl_egl_thread *owl_egl_thread_state(void) {
    struct owl_egl_thread *thread;

    pthread_once(&thread_state_once, thread_state_init);
    thread = pthread_getspecific(thread_state_key);
    if (thread == NULL) {
        thread = calloc(1, sizeof *thread);
        thread->error = EGL_SUCCESS;
        /* The spec's initial per-thread API is OpenGL ES, which we do
         * not implement at all; starting at OpenGL forgives clients
         * that forget eglBindAPI. */
        thread->api = EGL_OPENGL_API;
        pthread_setspecific(thread_state_key, thread);
    }
    return thread;
}

void owl_egl_set_error(EGLint error) {
    owl_egl_thread_state()->error = error;
}

EGLAPI EGLint EGLAPIENTRY eglGetError(void) {
    struct owl_egl_thread *thread = owl_egl_thread_state();
    EGLint error = thread->error;

    thread->error = EGL_SUCCESS;
    return error;
}

/* ---------- Displays ---------- */

static struct owl_egl_display *displays;

static struct owl_egl_display *display_from_handle(EGLDisplay handle) {
    struct owl_egl_display *display;

    pthread_mutex_lock(&owl_egl_lock);
    for (display = displays; display != NULL; display = display->next) {
        if ((EGLDisplay) display == handle) {
            break;
        }
    }
    pthread_mutex_unlock(&owl_egl_lock);
    return display;
}

static EGLDisplay display_get(struct wl_display *wl_display) {
    struct owl_egl_display *display;

    if (wl_display == NULL) {
        return EGL_NO_DISPLAY;
    }

    pthread_mutex_lock(&owl_egl_lock);
    for (display = displays; display != NULL; display = display->next) {
        if (display->wl_display == wl_display) {
            pthread_mutex_unlock(&owl_egl_lock);
            return (EGLDisplay) display;
        }
    }
    display = calloc(1, sizeof *display);
    if (display != NULL) {
        display->wl_display = wl_display;
        display->server_port = MACH_PORT_NULL;
        display->next = displays;
        displays = display;
    }
    pthread_mutex_unlock(&owl_egl_lock);
    return display != NULL ? (EGLDisplay) display : EGL_NO_DISPLAY;
}

EGLAPI EGLDisplay EGLAPIENTRY eglGetDisplay(EGLNativeDisplayType native) {
    /* With the Apple eglplatform.h fix, EGLNativeDisplayType is a
     * pointer; clients under owl pass their wl_display. We never own
     * a wl_display connection ourselves, so EGL_DEFAULT_DISPLAY is
     * not supported. */
    owl_egl_set_error(EGL_SUCCESS);
    return display_get((struct wl_display *) native);
}

EGLAPI EGLDisplay EGLAPIENTRY eglGetPlatformDisplay(
    EGLenum platform, void *native_display, const EGLAttrib *attrib_list)
{
    if (platform != EGL_PLATFORM_WAYLAND_KHR) {
        owl_egl_set_error(EGL_BAD_PARAMETER);
        return EGL_NO_DISPLAY;
    }
    owl_egl_set_error(EGL_SUCCESS);
    return display_get((struct wl_display *) native_display);
}

EGLAPI EGLDisplay EGLAPIENTRY eglGetPlatformDisplayEXT(
    EGLenum platform, void *native_display, const EGLint *attrib_list)
{
    return eglGetPlatformDisplay(platform, native_display, NULL);
}

EGLAPI EGLBoolean EGLAPIENTRY eglInitialize(
    EGLDisplay handle, EGLint *major, EGLint *minor)
{
    struct owl_egl_display *display = display_from_handle(handle);

    if (display == NULL) {
        owl_egl_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }

    pthread_mutex_lock(&owl_egl_lock);
    if (!display->initialized) {
        if (!owl_egl_display_connect(display)) {
            owl_egl_display_disconnect(display);
            pthread_mutex_unlock(&owl_egl_lock);
            owl_egl_set_error(EGL_NOT_INITIALIZED);
            return EGL_FALSE;
        }
        display->initialized = EGL_TRUE;
    }
    pthread_mutex_unlock(&owl_egl_lock);

    if (major != NULL) {
        *major = OWL_EGL_VERSION_MAJOR;
    }
    if (minor != NULL) {
        *minor = OWL_EGL_VERSION_MINOR;
    }
    owl_egl_set_error(EGL_SUCCESS);
    return EGL_TRUE;
}

EGLAPI EGLBoolean EGLAPIENTRY eglTerminate(EGLDisplay handle) {
    struct owl_egl_display *display = display_from_handle(handle);

    if (display == NULL) {
        owl_egl_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }
    /* Contexts and surfaces the application failed to destroy are not
     * tracked and not freed here; the display handle itself stays
     * valid for a later eglInitialize, per spec. */
    pthread_mutex_lock(&owl_egl_lock);
    if (display->initialized) {
        owl_egl_display_disconnect(display);
        display->initialized = EGL_FALSE;
    }
    pthread_mutex_unlock(&owl_egl_lock);
    owl_egl_set_error(EGL_SUCCESS);
    return EGL_TRUE;
}

static const char *client_extensions =
    "EGL_EXT_platform_base "
    "EGL_KHR_platform_wayland "
    "EGL_EXT_platform_wayland "
    "EGL_KHR_client_get_all_proc_addresses";

static const char *display_extensions =
    "EGL_KHR_get_all_proc_addresses";

EGLAPI const char *EGLAPIENTRY eglQueryString(
    EGLDisplay handle, EGLint name)
{
    struct owl_egl_display *display;

    if (handle == EGL_NO_DISPLAY) {
        if (name == EGL_EXTENSIONS) {
            owl_egl_set_error(EGL_SUCCESS);
            return client_extensions;
        }
        owl_egl_set_error(EGL_BAD_DISPLAY);
        return NULL;
    }

    display = display_from_handle(handle);
    if (display == NULL) {
        owl_egl_set_error(EGL_BAD_DISPLAY);
        return NULL;
    }
    if (!display->initialized) {
        owl_egl_set_error(EGL_NOT_INITIALIZED);
        return NULL;
    }

    owl_egl_set_error(EGL_SUCCESS);
    switch (name) {
    case EGL_VENDOR:
        return "owl";
    case EGL_VERSION:
        return "1.4 owl-egl";
    case EGL_CLIENT_APIS:
        return "OpenGL";
    case EGL_EXTENSIONS:
        return display_extensions;
    default:
        owl_egl_set_error(EGL_BAD_PARAMETER);
        return NULL;
    }
}

/* ---------- Configs ---------- */

static const struct owl_egl_config configs[] = {
    /* id  r  g  b  a  depth stencil */
    {  1,  8, 8, 8, 8, 24,   8 },
    {  2,  8, 8, 8, 8,  0,   0 },
    {  3,  8, 8, 8, 0, 24,   8 },
    {  4,  8, 8, 8, 0,  0,   0 },
};

#define OWL_EGL_CONFIG_COUNT \
    ((EGLint) (sizeof(configs) / sizeof(configs[0])))

static const struct owl_egl_config *config_from_handle(EGLConfig handle) {
    const struct owl_egl_config *config = handle;

    if (config >= configs && config < configs + OWL_EGL_CONFIG_COUNT) {
        return config;
    }
    return NULL;
}

static EGLBoolean config_get_attrib(const struct owl_egl_config *config,
                                    EGLint attribute, EGLint *value)
{
    switch (attribute) {
    case EGL_BUFFER_SIZE:
        *value = config->red_size + config->green_size +
                 config->blue_size + config->alpha_size;
        break;
    case EGL_RED_SIZE:
        *value = config->red_size;
        break;
    case EGL_GREEN_SIZE:
        *value = config->green_size;
        break;
    case EGL_BLUE_SIZE:
        *value = config->blue_size;
        break;
    case EGL_ALPHA_SIZE:
        *value = config->alpha_size;
        break;
    case EGL_DEPTH_SIZE:
        *value = config->depth_size;
        break;
    case EGL_STENCIL_SIZE:
        *value = config->stencil_size;
        break;
    case EGL_CONFIG_ID:
        *value = config->config_id;
        break;
    case EGL_SURFACE_TYPE:
        *value = EGL_WINDOW_BIT;
        break;
    case EGL_RENDERABLE_TYPE:
    case EGL_CONFORMANT:
        *value = EGL_OPENGL_BIT;
        break;
    case EGL_NATIVE_RENDERABLE:
        *value = EGL_TRUE;
        break;
    case EGL_NATIVE_VISUAL_ID:
    case EGL_NATIVE_VISUAL_TYPE:
        *value = 0;
        break;
    case EGL_CONFIG_CAVEAT:
        *value = EGL_NONE;
        break;
    case EGL_COLOR_BUFFER_TYPE:
        *value = EGL_RGB_BUFFER;
        break;
    case EGL_MIN_SWAP_INTERVAL:
        *value = 0;
        break;
    case EGL_MAX_SWAP_INTERVAL:
        *value = 1;
        break;
    case EGL_SAMPLES:
    case EGL_SAMPLE_BUFFERS:
    case EGL_LEVEL:
    case EGL_LUMINANCE_SIZE:
    case EGL_ALPHA_MASK_SIZE:
    case EGL_MAX_PBUFFER_WIDTH:
    case EGL_MAX_PBUFFER_HEIGHT:
    case EGL_MAX_PBUFFER_PIXELS:
        *value = 0;
        break;
    case EGL_TRANSPARENT_TYPE:
        *value = EGL_NONE;
        break;
    case EGL_TRANSPARENT_RED_VALUE:
    case EGL_TRANSPARENT_GREEN_VALUE:
    case EGL_TRANSPARENT_BLUE_VALUE:
        *value = 0;
        break;
    case EGL_BIND_TO_TEXTURE_RGB:
    case EGL_BIND_TO_TEXTURE_RGBA:
        *value = EGL_FALSE;
        break;
    default:
        return EGL_FALSE;
    }
    return EGL_TRUE;
}

EGLAPI EGLBoolean EGLAPIENTRY eglGetConfigAttrib(
    EGLDisplay handle, EGLConfig config_handle,
    EGLint attribute, EGLint *value)
{
    const struct owl_egl_config *config;

    if (display_from_handle(handle) == NULL) {
        owl_egl_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }
    config = config_from_handle(config_handle);
    if (config == NULL) {
        owl_egl_set_error(EGL_BAD_CONFIG);
        return EGL_FALSE;
    }
    if (value == NULL || !config_get_attrib(config, attribute, value)) {
        owl_egl_set_error(EGL_BAD_ATTRIBUTE);
        return EGL_FALSE;
    }
    owl_egl_set_error(EGL_SUCCESS);
    return EGL_TRUE;
}

EGLAPI EGLBoolean EGLAPIENTRY eglGetConfigs(
    EGLDisplay handle, EGLConfig *config_handles,
    EGLint config_size, EGLint *num_config)
{
    EGLint i, count;

    if (display_from_handle(handle) == NULL) {
        owl_egl_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }
    if (num_config == NULL) {
        owl_egl_set_error(EGL_BAD_PARAMETER);
        return EGL_FALSE;
    }
    count = OWL_EGL_CONFIG_COUNT;
    if (config_handles != NULL) {
        if (count > config_size) {
            count = config_size;
        }
        for (i = 0; i < count; i++) {
            config_handles[i] = (EGLConfig) &configs[i];
        }
    }
    *num_config = count;
    owl_egl_set_error(EGL_SUCCESS);
    return EGL_TRUE;
}

EGLAPI EGLBoolean EGLAPIENTRY eglChooseConfig(
    EGLDisplay handle, const EGLint *attrib_list,
    EGLConfig *config_handles, EGLint config_size, EGLint *num_config)
{
    /* Requested minimums / exact values. */
    EGLint want_surface_type = EGL_WINDOW_BIT;
    /* Spec default for EGL_RENDERABLE_TYPE is EGL_OPENGL_ES_BIT; we
     * honor that (an ES-only request correctly matches nothing here
     * and lets clients fall back to their desktop GL path). */
    EGLint want_renderable = EGL_OPENGL_ES_BIT;
    EGLint want_red = 0, want_green = 0, want_blue = 0, want_alpha = 0;
    EGLint want_depth = 0, want_stencil = 0, want_buffer_size = 0;
    EGLint want_samples = 0, want_sample_buffers = 0;
    EGLint want_config_id = EGL_DONT_CARE;
    EGLint i, count = 0;

    if (display_from_handle(handle) == NULL) {
        owl_egl_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }
    if (num_config == NULL) {
        owl_egl_set_error(EGL_BAD_PARAMETER);
        return EGL_FALSE;
    }

    for (i = 0; attrib_list != NULL && attrib_list[i] != EGL_NONE; i += 2) {
        EGLint attribute = attrib_list[i];
        EGLint value = attrib_list[i + 1];

        switch (attribute) {
        case EGL_SURFACE_TYPE:
            want_surface_type = value;
            break;
        case EGL_RENDERABLE_TYPE:
            want_renderable = value;
            break;
        case EGL_RED_SIZE:
            want_red = value;
            break;
        case EGL_GREEN_SIZE:
            want_green = value;
            break;
        case EGL_BLUE_SIZE:
            want_blue = value;
            break;
        case EGL_ALPHA_SIZE:
            want_alpha = value;
            break;
        case EGL_DEPTH_SIZE:
            want_depth = value;
            break;
        case EGL_STENCIL_SIZE:
            want_stencil = value;
            break;
        case EGL_BUFFER_SIZE:
            want_buffer_size = value;
            break;
        case EGL_SAMPLES:
            want_samples = value;
            break;
        case EGL_SAMPLE_BUFFERS:
            want_sample_buffers = value;
            break;
        case EGL_CONFIG_ID:
            want_config_id = value;
            break;
        /* Accepted and ignored: either matching is trivially true
         * for our configs, or clients pass defaults. */
        case EGL_CONFIG_CAVEAT:
        case EGL_COLOR_BUFFER_TYPE:
        case EGL_LEVEL:
        case EGL_NATIVE_RENDERABLE:
        case EGL_NATIVE_VISUAL_TYPE:
        case EGL_TRANSPARENT_TYPE:
        case EGL_TRANSPARENT_RED_VALUE:
        case EGL_TRANSPARENT_GREEN_VALUE:
        case EGL_TRANSPARENT_BLUE_VALUE:
        case EGL_MIN_SWAP_INTERVAL:
        case EGL_MAX_SWAP_INTERVAL:
        case EGL_LUMINANCE_SIZE:
        case EGL_ALPHA_MASK_SIZE:
        case EGL_BIND_TO_TEXTURE_RGB:
        case EGL_BIND_TO_TEXTURE_RGBA:
        case EGL_MAX_PBUFFER_WIDTH:
        case EGL_MAX_PBUFFER_HEIGHT:
        case EGL_MAX_PBUFFER_PIXELS:
            break;
        default:
            owl_egl_set_error(EGL_BAD_ATTRIBUTE);
            return EGL_FALSE;
        }
    }

    for (i = 0; i < OWL_EGL_CONFIG_COUNT; i++) {
        const struct owl_egl_config *config = &configs[i];

        if (want_config_id != EGL_DONT_CARE) {
            if (config->config_id != want_config_id) {
                continue;
            }
        } else {
            if (want_surface_type != EGL_DONT_CARE &&
                (EGL_WINDOW_BIT & want_surface_type) != want_surface_type)
            {
                continue;
            }
            if (want_renderable != EGL_DONT_CARE &&
                (EGL_OPENGL_BIT & want_renderable) != want_renderable)
            {
                continue;
            }
            if ((want_red != EGL_DONT_CARE &&
                 config->red_size < want_red) ||
                (want_green != EGL_DONT_CARE &&
                 config->green_size < want_green) ||
                (want_blue != EGL_DONT_CARE &&
                 config->blue_size < want_blue) ||
                (want_alpha != EGL_DONT_CARE &&
                 config->alpha_size < want_alpha) ||
                (want_depth != EGL_DONT_CARE &&
                 config->depth_size < want_depth) ||
                (want_stencil != EGL_DONT_CARE &&
                 config->stencil_size < want_stencil))
            {
                continue;
            }
            if (want_buffer_size != EGL_DONT_CARE &&
                config->red_size + config->green_size +
                config->blue_size + config->alpha_size < want_buffer_size)
            {
                continue;
            }
            if ((want_samples != EGL_DONT_CARE && want_samples > 0) ||
                (want_sample_buffers != EGL_DONT_CARE &&
                 want_sample_buffers > 0))
            {
                continue;
            }
        }

        if (config_handles != NULL && count < config_size) {
            config_handles[count] = (EGLConfig) config;
        }
        count++;
    }

    if (config_handles != NULL && count > config_size) {
        count = config_size;
    }
    *num_config = count;
    owl_egl_set_error(EGL_SUCCESS);
    return EGL_TRUE;
}

/* ---------- API binding ---------- */

EGLAPI EGLBoolean EGLAPIENTRY eglBindAPI(EGLenum api) {
    if (api != EGL_OPENGL_API) {
        owl_egl_set_error(EGL_BAD_PARAMETER);
        return EGL_FALSE;
    }
    owl_egl_thread_state()->api = api;
    owl_egl_set_error(EGL_SUCCESS);
    return EGL_TRUE;
}

EGLAPI EGLenum EGLAPIENTRY eglQueryAPI(void) {
    return owl_egl_thread_state()->api;
}

/* ---------- Contexts ---------- */

EGLAPI EGLContext EGLAPIENTRY eglCreateContext(
    EGLDisplay handle, EGLConfig config_handle,
    EGLContext share_handle, const EGLint *attrib_list)
{
    struct owl_egl_display *display = display_from_handle(handle);
    const struct owl_egl_config *config;
    struct owl_egl_context *context, *share = NULL;
    CGLPixelFormatAttribute attributes[] = {
        kCGLPFAAccelerated,
        kCGLPFAColorSize, (CGLPixelFormatAttribute) 24,
        kCGLPFAAlphaSize, (CGLPixelFormatAttribute) 8,
        (CGLPixelFormatAttribute) 0
    };
    CGLPixelFormatObj pixel_format;
    GLint virtual_screens = 0;
    CGLError cgl_error;
    EGLint i;

    if (display == NULL) {
        owl_egl_set_error(EGL_BAD_DISPLAY);
        return EGL_NO_CONTEXT;
    }
    if (!display->initialized) {
        owl_egl_set_error(EGL_NOT_INITIALIZED);
        return EGL_NO_CONTEXT;
    }
    config = config_from_handle(config_handle);
    if (config == NULL) {
        owl_egl_set_error(EGL_BAD_CONFIG);
        return EGL_NO_CONTEXT;
    }
    if (share_handle != EGL_NO_CONTEXT) {
        share = share_handle;
    }

    for (i = 0; attrib_list != NULL && attrib_list[i] != EGL_NONE; i += 2) {
        EGLint attribute = attrib_list[i];
        EGLint value = attrib_list[i + 1];

        switch (attribute) {
        case EGL_CONTEXT_CLIENT_VERSION: /* == EGL_CONTEXT_MAJOR_VERSION */
            if (value > 2) {
                /* Only the CGL legacy profile (GL 2.x) is offered. */
                owl_egl_set_error(EGL_BAD_MATCH);
                return EGL_NO_CONTEXT;
            }
            break;
        default:
            /* Without EGL_KHR_create_context advertised, clients
             * should not pass anything else; be forgiving. */
            break;
        }
    }

    cgl_error = CGLChoosePixelFormat(
        attributes, &pixel_format, &virtual_screens);
    if (cgl_error != kCGLNoError || virtual_screens == 0 ||
        pixel_format == NULL)
    {
        /* No accelerated renderer (VM, headless): fail here so the
         * user falls back to Mesa swrast rather than getting Apple's
         * software renderer by accident. */
        fprintf(
            stderr,
            "owl-egl: no accelerated CGL renderer: %s\n",
            CGLErrorString(cgl_error)
        );
        owl_egl_set_error(EGL_BAD_MATCH);
        return EGL_NO_CONTEXT;
    }

    context = calloc(1, sizeof *context);
    if (context == NULL) {
        CGLDestroyPixelFormat(pixel_format);
        owl_egl_set_error(EGL_BAD_ALLOC);
        return EGL_NO_CONTEXT;
    }
    context->display = display;
    context->config = config;

    cgl_error = CGLCreateContext(
        pixel_format,
        share != NULL ? share->cgl : NULL,
        &context->cgl
    );
    CGLDestroyPixelFormat(pixel_format);
    if (cgl_error != kCGLNoError) {
        fprintf(
            stderr,
            "owl-egl: CGLCreateContext failed: %s\n",
            CGLErrorString(cgl_error)
        );
        free(context);
        owl_egl_set_error(EGL_BAD_ALLOC);
        return EGL_NO_CONTEXT;
    }

    owl_egl_set_error(EGL_SUCCESS);
    return (EGLContext) context;
}

EGLAPI EGLBoolean EGLAPIENTRY eglDestroyContext(
    EGLDisplay handle, EGLContext context_handle)
{
    struct owl_egl_context *context = context_handle;
    struct owl_egl_thread *thread = owl_egl_thread_state();

    if (display_from_handle(handle) == NULL) {
        owl_egl_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }
    if (context == NULL) {
        owl_egl_set_error(EGL_BAD_CONTEXT);
        return EGL_FALSE;
    }
    if (thread->current_context == context) {
        CGLSetCurrentContext(NULL);
        thread->current_context = NULL;
        thread->current_surface = NULL;
        thread->zero_fbo = 0;
    }
    CGLDestroyContext(context->cgl);
    free(context);
    owl_egl_set_error(EGL_SUCCESS);
    return EGL_TRUE;
}

static int gl_has_extension(const char *extensions, const char *name) {
    size_t name_length = strlen(name);
    const char *position = extensions;

    if (extensions == NULL) {
        return 0;
    }
    while ((position = strstr(position, name)) != NULL) {
        if ((position == extensions || position[-1] == ' ') &&
            (position[name_length] == ' ' || position[name_length] == '\0'))
        {
            return 1;
        }
        position += name_length;
    }
    return 0;
}

/* Must run with the context current. */
static EGLBoolean context_check_extensions(struct owl_egl_context *context) {
    const char *extensions;

    if (context->checked_extensions) {
        return context->has_fbo && context->has_texture_rectangle;
    }
    context->checked_extensions = 1;

    extensions = (const char *) glGetString(GL_EXTENSIONS);
    context->has_fbo =
        gl_has_extension(extensions, "GL_EXT_framebuffer_object") ||
        gl_has_extension(extensions, "GL_ARB_framebuffer_object");
    context->has_texture_rectangle =
        gl_has_extension(extensions, "GL_ARB_texture_rectangle") ||
        gl_has_extension(extensions, "GL_EXT_texture_rectangle");
    context->has_packed_depth_stencil =
        gl_has_extension(extensions, "GL_EXT_packed_depth_stencil");

    if (!context->has_fbo || !context->has_texture_rectangle) {
        fprintf(
            stderr,
            "owl-egl: renderer %s lacks framebuffer objects or "
            "rectangle textures; hardware GL is not possible here\n",
            (const char *) glGetString(GL_RENDERER)
        );
        return EGL_FALSE;
    }
    return EGL_TRUE;
}

/* ---------- Surfaces ---------- */

static void window_destroyed(void *driver_private) {
    struct owl_egl_surface *surface = driver_private;

    if (surface != NULL) {
        surface->window = NULL;
    }
}

EGLAPI EGLSurface EGLAPIENTRY eglCreateWindowSurface(
    EGLDisplay handle, EGLConfig config_handle,
    EGLNativeWindowType native_window, const EGLint *attrib_list)
{
    struct owl_egl_display *display = display_from_handle(handle);
    const struct owl_egl_config *config;
    struct wl_egl_window *window = (struct wl_egl_window *) native_window;
    struct owl_egl_surface *surface;

    if (display == NULL) {
        owl_egl_set_error(EGL_BAD_DISPLAY);
        return EGL_NO_SURFACE;
    }
    if (!display->initialized) {
        owl_egl_set_error(EGL_NOT_INITIALIZED);
        return EGL_NO_SURFACE;
    }
    config = config_from_handle(config_handle);
    if (config == NULL) {
        owl_egl_set_error(EGL_BAD_CONFIG);
        return EGL_NO_SURFACE;
    }
    if (window == NULL || window->surface == NULL ||
        window->version != WL_EGL_WINDOW_VERSION)
    {
        /* An old-ABI wl_egl_window has a pointer where v3 keeps the
         * version; wayland ≥ 1.15 (everything on these Macs) is v3. */
        owl_egl_set_error(EGL_BAD_NATIVE_WINDOW);
        return EGL_NO_SURFACE;
    }
    if (window->driver_private != NULL) {
        /* Already the target of another EGL surface. */
        owl_egl_set_error(EGL_BAD_ALLOC);
        return EGL_NO_SURFACE;
    }

    surface = calloc(1, sizeof *surface);
    if (surface == NULL) {
        owl_egl_set_error(EGL_BAD_ALLOC);
        return EGL_NO_SURFACE;
    }
    surface->display = display;
    surface->config = config;
    surface->window = window;
    surface->wl_surface = window->surface;
    surface->swap_interval = 1;

    surface->wrapped_surface = wl_proxy_create_wrapper(window->surface);
    if (surface->wrapped_surface == NULL) {
        free(surface);
        owl_egl_set_error(EGL_BAD_ALLOC);
        return EGL_NO_SURFACE;
    }
    wl_proxy_set_queue(
        (struct wl_proxy *) surface->wrapped_surface, display->queue);

    window->driver_private = surface;
    window->destroy_window_callback = window_destroyed;

    owl_egl_set_error(EGL_SUCCESS);
    return (EGLSurface) surface;
}

EGLAPI EGLSurface EGLAPIENTRY eglCreatePlatformWindowSurface(
    EGLDisplay handle, EGLConfig config_handle,
    void *native_window, const EGLAttrib *attrib_list)
{
    return eglCreateWindowSurface(
        handle, config_handle, (EGLNativeWindowType) native_window, NULL);
}

EGLAPI EGLSurface EGLAPIENTRY eglCreatePlatformWindowSurfaceEXT(
    EGLDisplay handle, EGLConfig config_handle,
    void *native_window, const EGLint *attrib_list)
{
    return eglCreateWindowSurface(
        handle, config_handle, (EGLNativeWindowType) native_window, NULL);
}

EGLAPI EGLBoolean EGLAPIENTRY eglDestroySurface(
    EGLDisplay handle, EGLSurface surface_handle)
{
    struct owl_egl_surface *surface = surface_handle;
    struct owl_egl_thread *thread = owl_egl_thread_state();

    if (display_from_handle(handle) == NULL) {
        owl_egl_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }
    if (surface == NULL) {
        owl_egl_set_error(EGL_BAD_SURFACE);
        return EGL_FALSE;
    }

    if (thread->current_surface == surface) {
        thread->current_surface = NULL;
        thread->zero_fbo = 0;
    }
    if (surface->frame_callback != NULL) {
        wl_callback_destroy(surface->frame_callback);
        surface->frame_callback = NULL;
    }
    owl_egl_surface_destroy_buffers(surface);
    if (surface->window != NULL) {
        surface->window->driver_private = NULL;
        surface->window->destroy_window_callback = NULL;
    }
    wl_proxy_wrapper_destroy(surface->wrapped_surface);
    free(surface);
    owl_egl_set_error(EGL_SUCCESS);
    return EGL_TRUE;
}

EGLAPI EGLBoolean EGLAPIENTRY eglQuerySurface(
    EGLDisplay handle, EGLSurface surface_handle,
    EGLint attribute, EGLint *value)
{
    struct owl_egl_surface *surface = surface_handle;

    if (display_from_handle(handle) == NULL) {
        owl_egl_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }
    if (surface == NULL || value == NULL) {
        owl_egl_set_error(EGL_BAD_SURFACE);
        return EGL_FALSE;
    }

    owl_egl_set_error(EGL_SUCCESS);
    switch (attribute) {
    case EGL_WIDTH:
        *value = surface->window != NULL ? surface->window->width :
                 (surface->back != NULL ? surface->back->width : 0);
        return EGL_TRUE;
    case EGL_HEIGHT:
        *value = surface->window != NULL ? surface->window->height :
                 (surface->back != NULL ? surface->back->height : 0);
        return EGL_TRUE;
    case EGL_CONFIG_ID:
        *value = surface->config->config_id;
        return EGL_TRUE;
    case EGL_RENDER_BUFFER:
        *value = EGL_BACK_BUFFER;
        return EGL_TRUE;
    case EGL_SWAP_BEHAVIOR:
        *value = EGL_BUFFER_DESTROYED;
        return EGL_TRUE;
    case EGL_MULTISAMPLE_RESOLVE:
        *value = EGL_MULTISAMPLE_RESOLVE_DEFAULT;
        return EGL_TRUE;
    case EGL_HORIZONTAL_RESOLUTION:
    case EGL_VERTICAL_RESOLUTION:
    case EGL_PIXEL_ASPECT_RATIO:
        *value = EGL_UNKNOWN;
        return EGL_TRUE;
    case EGL_LARGEST_PBUFFER:
    case EGL_MIPMAP_TEXTURE:
    case EGL_MIPMAP_LEVEL:
        *value = 0;
        return EGL_TRUE;
    case EGL_TEXTURE_FORMAT:
    case EGL_TEXTURE_TARGET:
        *value = EGL_NO_TEXTURE;
        return EGL_TRUE;
    default:
        owl_egl_set_error(EGL_BAD_ATTRIBUTE);
        return EGL_FALSE;
    }
}

EGLAPI EGLBoolean EGLAPIENTRY eglSurfaceAttrib(
    EGLDisplay handle, EGLSurface surface_handle,
    EGLint attribute, EGLint value)
{
    owl_egl_set_error(EGL_SUCCESS);
    return EGL_TRUE;
}

/* ---------- Making current, swapping ---------- */

EGLAPI EGLBoolean EGLAPIENTRY eglMakeCurrent(
    EGLDisplay handle, EGLSurface draw_handle,
    EGLSurface read_handle, EGLContext context_handle)
{
    struct owl_egl_display *display = display_from_handle(handle);
    struct owl_egl_surface *surface = draw_handle;
    struct owl_egl_context *context = context_handle;
    struct owl_egl_thread *thread = owl_egl_thread_state();

    if (display == NULL) {
        owl_egl_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }

    if (context == NULL) {
        if (draw_handle != EGL_NO_SURFACE || read_handle != EGL_NO_SURFACE) {
            owl_egl_set_error(EGL_BAD_MATCH);
            return EGL_FALSE;
        }
        CGLSetCurrentContext(NULL);
        thread->current_display = NULL;
        thread->current_context = NULL;
        thread->current_surface = NULL;
        thread->zero_fbo = 0;
        owl_egl_set_error(EGL_SUCCESS);
        return EGL_TRUE;
    }

    if (draw_handle != read_handle || surface == NULL) {
        /* No separate read surfaces, no surfaceless contexts. */
        owl_egl_set_error(EGL_BAD_MATCH);
        return EGL_FALSE;
    }

    if (CGLSetCurrentContext(context->cgl) != kCGLNoError) {
        owl_egl_set_error(EGL_BAD_ACCESS);
        return EGL_FALSE;
    }

    if (!context_check_extensions(context)) {
        CGLSetCurrentContext(NULL);
        owl_egl_set_error(EGL_BAD_MATCH);
        return EGL_FALSE;
    }

    if (surface->back == NULL) {
        surface->back = owl_egl_surface_acquire_buffer(surface);
        if (surface->back == NULL) {
            CGLSetCurrentContext(NULL);
            owl_egl_set_error(EGL_BAD_ALLOC);
            return EGL_FALSE;
        }
    }
    if (!owl_egl_buffer_ensure_gl(surface->back, context)) {
        CGLSetCurrentContext(NULL);
        owl_egl_set_error(EGL_BAD_ALLOC);
        return EGL_FALSE;
    }

    owl_egl_fbzero_make_current(surface->back->fbo);

    if (!surface->viewport_initialized) {
        /* Per the EGL spec, the first time a context is made current
         * with a surface, viewport and scissor are set to the surface
         * size. Clients rely on this. */
        glViewport(0, 0, surface->back->width, surface->back->height);
        glScissor(0, 0, surface->back->width, surface->back->height);
        surface->viewport_initialized = 1;
    }

    thread->current_display = display;
    thread->current_context = context;
    thread->current_surface = surface;
    owl_egl_set_error(EGL_SUCCESS);
    return EGL_TRUE;
}

EGLAPI EGLBoolean EGLAPIENTRY eglSwapBuffers(
    EGLDisplay handle, EGLSurface surface_handle)
{
    struct owl_egl_surface *surface = surface_handle;
    struct owl_egl_thread *thread = owl_egl_thread_state();
    GLuint saved_binding;

    if (display_from_handle(handle) == NULL) {
        owl_egl_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }
    if (surface == NULL || thread->current_surface != surface ||
        thread->current_context == NULL)
    {
        owl_egl_set_error(EGL_BAD_SURFACE);
        return EGL_FALSE;
    }
    if (surface->window == NULL) {
        owl_egl_set_error(EGL_BAD_NATIVE_WINDOW);
        return EGL_FALSE;
    }

    /* Per Apple, glFlush is what makes IOSurface-backed rendering
     * visible to other processes (CGLFlushDrawable is for windowed
     * contexts). */
    glFlush();

    if (!owl_egl_surface_swap(surface)) {
        owl_egl_set_error(EGL_BAD_SURFACE);
        return EGL_FALSE;
    }

    /* Rotate "framebuffer 0" onto the new back buffer. The client may
     * be inside its own FBO mid-frame; preserve that binding. */
    saved_binding = owl_egl_fbzero_real_binding();
    if (!owl_egl_buffer_ensure_gl(surface->back, thread->current_context)) {
        owl_egl_set_error(EGL_BAD_ALLOC);
        return EGL_FALSE;
    }
    owl_egl_fbzero_rebind(surface->back->fbo);
    if (!thread->app_at_zero) {
        owl_egl_fbzero_restore(saved_binding);
    }

    owl_egl_set_error(EGL_SUCCESS);
    return EGL_TRUE;
}

EGLAPI EGLBoolean EGLAPIENTRY eglSwapInterval(
    EGLDisplay handle, EGLint interval)
{
    struct owl_egl_thread *thread = owl_egl_thread_state();

    if (display_from_handle(handle) == NULL) {
        owl_egl_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }
    if (thread->current_surface == NULL) {
        owl_egl_set_error(EGL_BAD_SURFACE);
        return EGL_FALSE;
    }
    if (interval < 0) {
        interval = 0;
    }
    if (interval > 1) {
        interval = 1;
    }
    thread->current_surface->swap_interval = interval;
    owl_egl_set_error(EGL_SUCCESS);
    return EGL_TRUE;
}

EGLAPI EGLContext EGLAPIENTRY eglGetCurrentContext(void) {
    return (EGLContext) owl_egl_thread_state()->current_context;
}

EGLAPI EGLSurface EGLAPIENTRY eglGetCurrentSurface(EGLint readdraw) {
    if (readdraw != EGL_READ && readdraw != EGL_DRAW) {
        owl_egl_set_error(EGL_BAD_PARAMETER);
        return EGL_NO_SURFACE;
    }
    return (EGLSurface) owl_egl_thread_state()->current_surface;
}

EGLAPI EGLDisplay EGLAPIENTRY eglGetCurrentDisplay(void) {
    struct owl_egl_display *display =
        owl_egl_thread_state()->current_display;

    return display != NULL ? (EGLDisplay) display : EGL_NO_DISPLAY;
}

EGLAPI EGLBoolean EGLAPIENTRY eglQueryContext(
    EGLDisplay handle, EGLContext context_handle,
    EGLint attribute, EGLint *value)
{
    struct owl_egl_context *context = context_handle;

    if (display_from_handle(handle) == NULL) {
        owl_egl_set_error(EGL_BAD_DISPLAY);
        return EGL_FALSE;
    }
    if (context == NULL || value == NULL) {
        owl_egl_set_error(EGL_BAD_CONTEXT);
        return EGL_FALSE;
    }
    owl_egl_set_error(EGL_SUCCESS);
    switch (attribute) {
    case EGL_CONFIG_ID:
        *value = context->config->config_id;
        return EGL_TRUE;
    case EGL_CONTEXT_CLIENT_TYPE:
        *value = EGL_OPENGL_API;
        return EGL_TRUE;
    case EGL_CONTEXT_CLIENT_VERSION:
        *value = 2;
        return EGL_TRUE;
    case EGL_RENDER_BUFFER:
        *value = EGL_BACK_BUFFER;
        return EGL_TRUE;
    default:
        owl_egl_set_error(EGL_BAD_ATTRIBUTE);
        return EGL_FALSE;
    }
}

/* ---------- Waiting, thread release ---------- */

EGLAPI EGLBoolean EGLAPIENTRY eglWaitClient(void) {
    if (owl_egl_thread_state()->current_context != NULL) {
        glFinish();
    }
    owl_egl_set_error(EGL_SUCCESS);
    return EGL_TRUE;
}

EGLAPI EGLBoolean EGLAPIENTRY eglWaitGL(void) {
    return eglWaitClient();
}

EGLAPI EGLBoolean EGLAPIENTRY eglWaitNative(EGLint engine) {
    owl_egl_set_error(EGL_SUCCESS);
    return EGL_TRUE;
}

EGLAPI EGLBoolean EGLAPIENTRY eglReleaseThread(void) {
    struct owl_egl_thread *thread = owl_egl_thread_state();

    if (thread->current_context != NULL) {
        CGLSetCurrentContext(NULL);
    }
    thread->current_display = NULL;
    thread->current_context = NULL;
    thread->current_surface = NULL;
    thread->zero_fbo = 0;
    thread->error = EGL_SUCCESS;
    thread->api = EGL_OPENGL_API;
    return EGL_TRUE;
}

/* ---------- Unsupported surface kinds and EGL 1.5 stubs ---------- */

EGLAPI EGLSurface EGLAPIENTRY eglCreatePbufferSurface(
    EGLDisplay handle, EGLConfig config_handle, const EGLint *attrib_list)
{
    owl_egl_set_error(EGL_BAD_MATCH);
    return EGL_NO_SURFACE;
}

EGLAPI EGLSurface EGLAPIENTRY eglCreatePixmapSurface(
    EGLDisplay handle, EGLConfig config_handle,
    EGLNativePixmapType pixmap, const EGLint *attrib_list)
{
    owl_egl_set_error(EGL_BAD_MATCH);
    return EGL_NO_SURFACE;
}

EGLAPI EGLSurface EGLAPIENTRY eglCreatePlatformPixmapSurface(
    EGLDisplay handle, EGLConfig config_handle,
    void *native_pixmap, const EGLAttrib *attrib_list)
{
    owl_egl_set_error(EGL_BAD_MATCH);
    return EGL_NO_SURFACE;
}

EGLAPI EGLSurface EGLAPIENTRY eglCreatePbufferFromClientBuffer(
    EGLDisplay handle, EGLenum buftype, EGLClientBuffer buffer,
    EGLConfig config_handle, const EGLint *attrib_list)
{
    owl_egl_set_error(EGL_BAD_MATCH);
    return EGL_NO_SURFACE;
}

EGLAPI EGLBoolean EGLAPIENTRY eglBindTexImage(
    EGLDisplay handle, EGLSurface surface_handle, EGLint buffer)
{
    owl_egl_set_error(EGL_BAD_SURFACE);
    return EGL_FALSE;
}

EGLAPI EGLBoolean EGLAPIENTRY eglReleaseTexImage(
    EGLDisplay handle, EGLSurface surface_handle, EGLint buffer)
{
    owl_egl_set_error(EGL_BAD_SURFACE);
    return EGL_FALSE;
}

EGLAPI EGLBoolean EGLAPIENTRY eglCopyBuffers(
    EGLDisplay handle, EGLSurface surface_handle,
    EGLNativePixmapType target)
{
    owl_egl_set_error(EGL_BAD_NATIVE_PIXMAP);
    return EGL_FALSE;
}

EGLAPI EGLSync EGLAPIENTRY eglCreateSync(
    EGLDisplay handle, EGLenum type, const EGLAttrib *attrib_list)
{
    owl_egl_set_error(EGL_BAD_PARAMETER);
    return EGL_NO_SYNC;
}

EGLAPI EGLBoolean EGLAPIENTRY eglDestroySync(
    EGLDisplay handle, EGLSync sync)
{
    owl_egl_set_error(EGL_BAD_PARAMETER);
    return EGL_FALSE;
}

EGLAPI EGLint EGLAPIENTRY eglClientWaitSync(
    EGLDisplay handle, EGLSync sync, EGLint flags, EGLTime timeout)
{
    owl_egl_set_error(EGL_BAD_PARAMETER);
    return EGL_FALSE;
}

EGLAPI EGLBoolean EGLAPIENTRY eglWaitSync(
    EGLDisplay handle, EGLSync sync, EGLint flags)
{
    owl_egl_set_error(EGL_BAD_PARAMETER);
    return EGL_FALSE;
}

EGLAPI EGLBoolean EGLAPIENTRY eglGetSyncAttrib(
    EGLDisplay handle, EGLSync sync, EGLint attribute, EGLAttrib *value)
{
    owl_egl_set_error(EGL_BAD_PARAMETER);
    return EGL_FALSE;
}

EGLAPI EGLImage EGLAPIENTRY eglCreateImage(
    EGLDisplay handle, EGLContext context, EGLenum target,
    EGLClientBuffer buffer, const EGLAttrib *attrib_list)
{
    owl_egl_set_error(EGL_BAD_PARAMETER);
    return EGL_NO_IMAGE;
}

EGLAPI EGLBoolean EGLAPIENTRY eglDestroyImage(
    EGLDisplay handle, EGLImage image)
{
    owl_egl_set_error(EGL_BAD_PARAMETER);
    return EGL_FALSE;
}

/* KHR-suffixed aliases, also exported by Mesa's libEGL; kept so that
 * dyld can bind them if a client references them directly. */

EGLAPI EGLImageKHR EGLAPIENTRY eglCreateImageKHR(
    EGLDisplay handle, EGLContext context, EGLenum target,
    EGLClientBuffer buffer, const EGLint *attrib_list)
{
    owl_egl_set_error(EGL_BAD_PARAMETER);
    return EGL_NO_IMAGE_KHR;
}

EGLAPI EGLBoolean EGLAPIENTRY eglDestroyImageKHR(
    EGLDisplay handle, EGLImageKHR image)
{
    owl_egl_set_error(EGL_BAD_PARAMETER);
    return EGL_FALSE;
}

EGLAPI EGLBoolean EGLAPIENTRY eglSwapBuffersWithDamageKHR(
    EGLDisplay handle, EGLSurface surface_handle,
    const EGLint *rects, EGLint n_rects)
{
    return eglSwapBuffers(handle, surface_handle);
}

EGLAPI EGLBoolean EGLAPIENTRY eglSwapBuffersWithDamageEXT(
    EGLDisplay handle, EGLSurface surface_handle,
    const EGLint *rects, EGLint n_rects)
{
    return eglSwapBuffers(handle, surface_handle);
}

/* ---------- eglGetProcAddress ---------- */

struct proc_entry {
    const char *name;
    void *function;
};

static void *opengl_framework;
static pthread_once_t opengl_framework_once = PTHREAD_ONCE_INIT;

static void opengl_framework_open(void) {
    opengl_framework = dlopen(
        "/System/Library/Frameworks/OpenGL.framework/OpenGL",
        RTLD_LAZY | RTLD_LOCAL
    );
}

EGLAPI __eglMustCastToProperFunctionPointerType EGLAPIENTRY
eglGetProcAddress(const char *name)
{
    static const struct proc_entry egl_procs[] = {
        { "eglGetError", (void *) eglGetError },
        { "eglGetDisplay", (void *) eglGetDisplay },
        { "eglGetPlatformDisplay", (void *) eglGetPlatformDisplay },
        { "eglGetPlatformDisplayEXT", (void *) eglGetPlatformDisplayEXT },
        { "eglInitialize", (void *) eglInitialize },
        { "eglTerminate", (void *) eglTerminate },
        { "eglQueryString", (void *) eglQueryString },
        { "eglGetConfigs", (void *) eglGetConfigs },
        { "eglChooseConfig", (void *) eglChooseConfig },
        { "eglGetConfigAttrib", (void *) eglGetConfigAttrib },
        { "eglBindAPI", (void *) eglBindAPI },
        { "eglQueryAPI", (void *) eglQueryAPI },
        { "eglCreateContext", (void *) eglCreateContext },
        { "eglDestroyContext", (void *) eglDestroyContext },
        { "eglCreateWindowSurface", (void *) eglCreateWindowSurface },
        { "eglCreatePlatformWindowSurface",
          (void *) eglCreatePlatformWindowSurface },
        { "eglCreatePlatformWindowSurfaceEXT",
          (void *) eglCreatePlatformWindowSurfaceEXT },
        { "eglDestroySurface", (void *) eglDestroySurface },
        { "eglQuerySurface", (void *) eglQuerySurface },
        { "eglSurfaceAttrib", (void *) eglSurfaceAttrib },
        { "eglMakeCurrent", (void *) eglMakeCurrent },
        { "eglSwapBuffers", (void *) eglSwapBuffers },
        { "eglSwapBuffersWithDamageKHR",
          (void *) eglSwapBuffersWithDamageKHR },
        { "eglSwapBuffersWithDamageEXT",
          (void *) eglSwapBuffersWithDamageEXT },
        { "eglSwapInterval", (void *) eglSwapInterval },
        { "eglGetCurrentContext", (void *) eglGetCurrentContext },
        { "eglGetCurrentSurface", (void *) eglGetCurrentSurface },
        { "eglGetCurrentDisplay", (void *) eglGetCurrentDisplay },
        { "eglQueryContext", (void *) eglQueryContext },
        { "eglWaitClient", (void *) eglWaitClient },
        { "eglWaitGL", (void *) eglWaitGL },
        { "eglWaitNative", (void *) eglWaitNative },
        { "eglReleaseThread", (void *) eglReleaseThread },
        { "eglGetProcAddress", (void *) eglGetProcAddress },
        { NULL, NULL }
    };
    const struct proc_entry *entry;
    void *function;

    if (name == NULL) {
        return NULL;
    }

    if (strncmp(name, "egl", 3) == 0) {
        for (entry = egl_procs; entry->name != NULL; entry++) {
            if (strcmp(entry->name, name) == 0) {
                return (__eglMustCastToProperFunctionPointerType)
                    entry->function;
            }
        }
        return NULL;
    }

    /* The framebuffer-zero wrappers shadow a handful of GL entry
     * points; everything else comes straight from Apple's OpenGL
     * framework (EGL_KHR_get_all_proc_addresses). */
    function = owl_egl_fbzero_lookup(name);
    if (function != NULL) {
        return (__eglMustCastToProperFunctionPointerType) function;
    }

    pthread_once(&opengl_framework_once, opengl_framework_open);
    if (opengl_framework == NULL) {
        return NULL;
    }
    return (__eglMustCastToProperFunctionPointerType)
        dlsym(opengl_framework, name);
}
