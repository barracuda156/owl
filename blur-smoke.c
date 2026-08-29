/* blur-smoke.c -- minimal ext_background_effect_manager_v1 test client.
 *
 * Maps a ~400x300 ARGB8888 wl_shell toplevel filled with ~55%-alpha
 * dark gray, requests a background effect for it, and sets a blur
 * region covering the whole surface.
 *
 * Expected visuals on a compositor with a working blur backend
 * (e.g. owl on Apple, CGSSetWindowBackgroundBlurRadius resolved):
 * the window shows dark, semi-transparent, FROSTED GLASS -- content
 * behind it visibly blurred, not just dimmed. After ~8s the blur
 * region is cleared (set_blur_region(NULL) + commit): the window
 * should snap back to plain semi-transparent dark gray with no blur,
 * while staying mapped. It exits cleanly ~3s after that. If the
 * manager exists but capabilities() never advertised blur (backend
 * unavailable -- GNUstep, or a macOS where the private symbols are
 * missing), this prints a message and exits(1) before ever mapping
 * a window.
 *
 * No memfd on Darwin, so the buffer is staged through a mkstemp'd
 * file that's unlinked immediately after creation (same technique
 * as gamma-smoke.c).
 *
 * Build (against this repo's vendored protocol XML):
 *   wayland-scanner client-header \
 *       Sources/Protocol/ext-background-effect-v1.xml \
 *       ext-background-effect-v1-client.h
 *   wayland-scanner private-code \
 *       Sources/Protocol/ext-background-effect-v1.xml \
 *       ext-background-effect-v1-client.c
 *   cc blur-smoke.c ext-background-effect-v1-client.c \
 *       -o blur-smoke -lwayland-client
 *
 * Compile-check only (no link needed, no display required):
 *   gcc -std=gnu99 -o /dev/null -c blur-smoke.c \
 *       $(pkg-config --cflags wayland-client)
 */

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

#include <wayland-client.h>

#include "ext-background-effect-v1-client.h"

#define SURFACE_WIDTH 400
#define SURFACE_HEIGHT 300

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_shell *shell;
static struct ext_background_effect_manager_v1 *manager;
static int blur_capable;

static void registry_global(
    void *data,
    struct wl_registry *registry,
    uint32_t name,
    const char *interface,
    uint32_t version
) {
    if (strcmp(interface, wl_compositor_interface.name) == 0) {
        compositor = wl_registry_bind(
            registry, name, &wl_compositor_interface, 1);
    } else if (strcmp(interface, wl_shm_interface.name) == 0) {
        shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, wl_shell_interface.name) == 0) {
        shell = wl_registry_bind(registry, name, &wl_shell_interface, 1);
    } else if (strcmp(
        interface, ext_background_effect_manager_v1_interface.name) == 0
    ) {
        manager = wl_registry_bind(
            registry, name, &ext_background_effect_manager_v1_interface, 1);
    }
}

static void registry_global_remove(
    void *data,
    struct wl_registry *registry,
    uint32_t name
) {
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove
};

static void background_effect_manager_capabilities(
    void *data,
    struct ext_background_effect_manager_v1 *manager_,
    uint32_t flags
) {
    if (flags & EXT_BACKGROUND_EFFECT_MANAGER_V1_CAPABILITY_BLUR) {
        blur_capable = 1;
    }
}

static const struct ext_background_effect_manager_v1_listener
manager_listener = {
    .capabilities = background_effect_manager_capabilities
};

static void shell_surface_ping(
    void *data,
    struct wl_shell_surface *shell_surface,
    uint32_t serial
) {
    wl_shell_surface_pong(shell_surface, serial);
}

static void shell_surface_configure(
    void *data,
    struct wl_shell_surface *shell_surface,
    uint32_t edges,
    int32_t width,
    int32_t height
) {
}

static void shell_surface_popup_done(
    void *data,
    struct wl_shell_surface *shell_surface
) {
}

static const struct wl_shell_surface_listener shell_surface_listener = {
    .ping = shell_surface_ping,
    .configure = shell_surface_configure,
    .popup_done = shell_surface_popup_done
};

/* Stages a SURFACE_WIDTH x SURFACE_HEIGHT ARGB8888 (premultiplied,
 * host byte order) buffer filled with ~55%-alpha dark gray into a
 * temp file and wraps it in a wl_buffer. The fd is closed locally
 * once the pool is created -- wl_shm_pool keeps its own reference
 * via the mmap. */
static struct wl_buffer *create_translucent_buffer(void) {
    char path[] = "/tmp/blur-smoke-XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0) {
        fprintf(stderr, "mkstemp: %s\n", strerror(errno));
        return NULL;
    }
    unlink(path);

    int32_t stride = SURFACE_WIDTH * 4;
    size_t size = (size_t) stride * SURFACE_HEIGHT;
    if (ftruncate(fd, (off_t) size) != 0) {
        fprintf(stderr, "ftruncate: %s\n", strerror(errno));
        close(fd);
        return NULL;
    }

    void *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) {
        fprintf(stderr, "mmap: %s\n", strerror(errno));
        close(fd);
        return NULL;
    }

    /* ~55% alpha, dark gray, premultiplied: alpha 140/255, gray 60
     * before premultiplying becomes 60*140/255 = 33 per channel. */
    uint32_t pixel = (140u << 24) | (33u << 16) | (33u << 8) | 33u;
    uint32_t *pixels = data;
    size_t count = (size_t) SURFACE_WIDTH * SURFACE_HEIGHT;
    size_t i;
    for (i = 0; i < count; i++) {
        pixels[i] = pixel;
    }
    munmap(data, size);

    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t) size);
    close(fd);

    struct wl_buffer *buffer = wl_shm_pool_create_buffer(
        pool, 0, SURFACE_WIDTH, SURFACE_HEIGHT, stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    return buffer;
}

int main(void) {
    struct wl_display *display = wl_display_connect(NULL);
    if (display == NULL) {
        fprintf(stderr, "wl_display_connect failed\n");
        return 1;
    }

    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);

    if (compositor == NULL || shm == NULL || shell == NULL
        || manager == NULL)
    {
        fprintf(
            stderr,
            "missing wl_compositor, wl_shm, wl_shell, or "
            "ext_background_effect_manager_v1\n"
        );
        return 1;
    }

    /* capabilities() is sent as part of the bind burst; a roundtrip
     * guarantees it has arrived before we check it. */
    ext_background_effect_manager_v1_add_listener(
        manager, &manager_listener, NULL);
    wl_display_roundtrip(display);

    if (!blur_capable) {
        fprintf(stderr, "compositor does not advertise blur capability\n");
        return 1;
    }

    struct wl_buffer *buffer = create_translucent_buffer();
    if (buffer == NULL) {
        return 1;
    }

    struct wl_surface *surface = wl_compositor_create_surface(compositor);
    struct wl_shell_surface *shell_surface =
        wl_shell_get_shell_surface(shell, surface);
    wl_shell_surface_add_listener(shell_surface, &shell_surface_listener, NULL);
    wl_shell_surface_set_toplevel(shell_surface);

    struct ext_background_effect_surface_v1 *effect =
        ext_background_effect_manager_v1_get_background_effect(
            manager, surface);

    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage(surface, 0, 0, SURFACE_WIDTH, SURFACE_HEIGHT);

    struct wl_region *region = wl_compositor_create_region(compositor);
    wl_region_add(region, 0, 0, SURFACE_WIDTH, SURFACE_HEIGHT);
    ext_background_effect_surface_v1_set_blur_region(effect, region);
    /* Copy semantics per spec: safe to destroy right away. */
    wl_region_destroy(region);

    wl_surface_commit(surface);
    wl_display_roundtrip(display);

    printf("blur region set, showing frosted glass for 8s...\n");
    sleep(8);

    ext_background_effect_surface_v1_set_blur_region(effect, NULL);
    wl_surface_commit(surface);
    wl_display_roundtrip(display);

    printf("blur removed, exiting in 3s...\n");
    sleep(3);

    ext_background_effect_surface_v1_destroy(effect);
    wl_shell_surface_destroy(shell_surface);
    wl_surface_destroy(surface);
    wl_buffer_destroy(buffer);
    ext_background_effect_manager_v1_destroy(manager);
    wl_display_disconnect(display);
    return 0;
}
