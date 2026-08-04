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

#import "OwlFeatures.h"
#ifdef OWL_HAS_IOSURFACE

#import "OwlIOSurfaceBuffer.h"
#import <OpenGL/gl.h>
#import <OpenGL/CGLIOSurface.h>


@implementation OwlIOSurfaceBuffer

- (id) initWithResource: (struct wl_resource *) resource
            surfacePort: (mach_port_t) surfacePort
{
    self = [super initWithResource: resource];
    _surface = IOSurfaceLookupFromMachPort(surfacePort);
    if (_surface != NULL) {
        IOSurfaceIncrementUseCount(_surface);
    }
    return self;
}

- (IOSurfaceRef) iosurface {
    return _surface;
}

- (void) destroyTextureIfPossible {
    // The texture name lives in the surface's GL context. We can
    // only delete it while that context is current; otherwise it
    // dies together with its context (the surface owns the context
    // for as long as it shows GL buffers).
    if (_tex != 0 && _texContext != NULL &&
        _texContext == CGLGetCurrentContext())
    {
        glDeleteTextures(1, &_tex);
        _tex = 0;
        _texContext = NULL;
    }
}

- (void) dealloc {
    [self destroyTextureIfPossible];
    if (_surface != NULL) {
        IOSurfaceDecrementUseCount(_surface);
        CFRelease(_surface);
    }
    [super dealloc];
}

- (void) invalidate {
    // Nothing to recompute: the texture is bound directly to the
    // IOSurface memory by CGLTexImageIOSurface2D, so the client's
    // new frame (made coherent by its glFlush) is picked up when we
    // draw. If stale content is ever observed, the fix is to re-run
    // CGLTexImageIOSurface2D here rather than to recreate textures
    // every frame.
}

- (NSSize) size {
    size_t width, height;

    if (_surface == NULL) {
        return NSZeroSize;
    }
    width = IOSurfaceGetWidth(_surface);
    height = IOSurfaceGetHeight(_surface);
    return NSMakeSize(width, height);
}

- (BOOL) needsGLForRendering {
    return YES;
}

- (void) setupTextureWithCGLContext: (CGLContextObj) context {
    glGenTextures(1, &_tex);
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, _tex);

    size_t width = IOSurfaceGetWidth(_surface);
    size_t height = IOSurfaceGetHeight(_surface);

    CGLTexImageIOSurface2D(
        context,
        GL_TEXTURE_RECTANGLE_ARB,  // target
        GL_RGBA,  // internal_format
        width,
        height,
        GL_BGRA,  // format
        GL_UNSIGNED_INT_8_8_8_8_REV,  // type
        _surface,
        0  // plane
    );

    glTexParameteri(
        GL_TEXTURE_RECTANGLE_ARB,
        GL_TEXTURE_MIN_FILTER,
        GL_LINEAR
    );
    glTexParameteri(
        GL_TEXTURE_RECTANGLE_ARB,
        GL_TEXTURE_MAG_FILTER,
        GL_LINEAR
    );
    glTexParameteri(
        GL_TEXTURE_RECTANGLE_ARB,
        GL_TEXTURE_WRAP_S,
        GL_CLAMP_TO_EDGE
    );
    glTexParameteri(
        GL_TEXTURE_RECTANGLE_ARB,
        GL_TEXTURE_WRAP_T,
        GL_CLAMP_TO_EDGE
    );
}

- (void) drawInRect: (NSRect) rect {
    if (_surface == NULL) {
        return;
    }
    glViewport(0, 0, rect.size.width, rect.size.height);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrtho(0, rect.size.width, 0, rect.size.height, -1, 1);

    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();

    struct {
        GLfloat x, y;
    } coord[4] = {
        {0, 0},
        {rect.size.width, 0},
        {0, rect.size.height},
        {rect.size.width, rect.size.height}
    };

    glEnable(GL_TEXTURE_RECTANGLE_ARB);

    // Create the texture once per GL context and reuse it: it is
    // backed by the IOSurface memory itself, so it does not need
    // recreating when the client draws a new frame. (Recreating it
    // here used to leak a texture name every single frame.)
    NSOpenGLContext *currentContext = [NSOpenGLContext currentContext];
    CGLContextObj cglContext = [currentContext CGLContextObj];
    if (_tex == 0 || _texContext != cglContext) {
        // Any previous name belonged to a context that is gone
        // (surfaces tear their context down only when the buffer
        // kind changes or on dealloc).
        _tex = 0;
        [self setupTextureWithCGLContext: cglContext];
        _texContext = cglContext;
    }
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, _tex);

    glEnableClientState(GL_VERTEX_ARRAY);
    glEnableClientState(GL_TEXTURE_COORD_ARRAY);

    glPushMatrix();
    glTexCoordPointer(2, GL_FLOAT, 0, coord);
    glVertexPointer(2, GL_FLOAT, 0, coord);

    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

    glPopMatrix();

    glFlush();
}

- (void) notifyDetached {
    [self sendRelease];
}

@end

#endif /* OWL_HAS_IOSURFACE */
