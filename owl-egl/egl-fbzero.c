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

/* Framebuffer-zero remapping.
 *
 * An EGL client renders its final output to framebuffer 0, but under
 * CGL with no drawable there is no usable framebuffer 0: the window
 * surface is an IOSurface-backed FBO. eglMakeCurrent leaves that FBO
 * bound, so a client that never explicitly binds framebuffer 0 works
 * as-is. Clients that bind their own FBOs and then "return to 0"
 * (mpv) resolve GL through eglGetProcAddress, which hands them the
 * wrappers below: binding 0 binds the surface's back FBO instead, and
 * querying the binding reports the FBO as 0. The remapping is
 * per-thread, like the current context itself.
 *
 * Clients that both link Apple GL symbols directly AND explicitly
 * bind framebuffer 0 would bypass this; none of the current targets
 * do. The contingency for such clients is the pbuffer route described
 * in HWGL.md.
 */

#include "owl-egl-private.h"

#include <string.h>

#ifndef GL_FRAMEBUFFER_BINDING_EXT
#define GL_FRAMEBUFFER_BINDING_EXT 0x8CA6
#endif
#ifndef GL_READ_FRAMEBUFFER_BINDING_EXT
#define GL_READ_FRAMEBUFFER_BINDING_EXT 0x8CAA
#endif

static void owl_egl_glBindFramebuffer(GLenum target, GLuint framebuffer) {
    struct owl_egl_thread *thread = owl_egl_thread_state();

    if (framebuffer == 0 && thread->zero_fbo != 0) {
        thread->app_at_zero = 1;
        framebuffer = thread->zero_fbo;
    } else {
        thread->app_at_zero = (framebuffer == thread->zero_fbo);
    }
    glBindFramebufferEXT(target, framebuffer);
}

static void owl_egl_glGetIntegerv(GLenum pname, GLint *params) {
    struct owl_egl_thread *thread = owl_egl_thread_state();

    glGetIntegerv(pname, params);
    if (params == NULL || thread->zero_fbo == 0) {
        return;
    }
    if (pname == GL_FRAMEBUFFER_BINDING_EXT ||
        pname == GL_READ_FRAMEBUFFER_BINDING_EXT) {
        if (*params == (GLint) thread->zero_fbo) {
            *params = 0;
        }
    }
}

void *owl_egl_fbzero_lookup(const char *name) {
    if (strcmp(name, "glBindFramebuffer") == 0 ||
        strcmp(name, "glBindFramebufferEXT") == 0 ||
        strcmp(name, "glBindFramebufferOES") == 0) {
        return (void *) owl_egl_glBindFramebuffer;
    }
    if (strcmp(name, "glGetIntegerv") == 0) {
        return (void *) owl_egl_glGetIntegerv;
    }
    return NULL;
}

void owl_egl_fbzero_make_current(GLuint fbo) {
    struct owl_egl_thread *thread = owl_egl_thread_state();

    thread->zero_fbo = fbo;
    thread->app_at_zero = 1;
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, fbo);
}

/* After eglSwapBuffers rotates to a new back buffer, "0" must map to
 * the new FBO; rebind only if the client is logically at 0 (it may be
 * inside its own FBO mid-frame). */
void owl_egl_fbzero_rebind(GLuint fbo) {
    struct owl_egl_thread *thread = owl_egl_thread_state();

    thread->zero_fbo = fbo;
    if (thread->app_at_zero) {
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, fbo);
    }
}

GLuint owl_egl_fbzero_real_binding(void) {
    GLint binding = 0;

    glGetIntegerv(GL_FRAMEBUFFER_BINDING_EXT, &binding);
    return (GLuint) binding;
}

void owl_egl_fbzero_restore(GLuint fbo) {
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, fbo);
}
