/* gamma-smoke.c -- minimal zwlr_gamma_control_manager_v1 test client.
 *
 * Binds the manager and the first wl_output, requests a gamma
 * control, and on gamma_size writes a warm ramp (blue channel
 * scaled down) through a set_gamma request. Sleeps a few seconds
 * before exiting so the compositor's restore-on-disconnect path
 * gets exercised.
 *
 * No memfd on Darwin, so the gamma table is staged through a
 * mkstemp'd file that's unlinked immediately after creation.
 *
 * Build (against this repo's vendored protocol XML):
 *   wayland-scanner client-header \
 *       Sources/Protocol/wlr-gamma-control-unstable-v1.xml \
 *       wlr-gamma-control-unstable-v1-client.h
 *   wayland-scanner private-code \
 *       Sources/Protocol/wlr-gamma-control-unstable-v1.xml \
 *       wlr-gamma-control-unstable-v1-client.c
 *   cc gamma-smoke.c wlr-gamma-control-unstable-v1-client.c \
 *       -o gamma-smoke -lwayland-client
 */

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <wayland-client.h>

#include "wlr-gamma-control-unstable-v1-client.h"

static struct wl_output *output;
static struct zwlr_gamma_control_manager_v1 *manager;
static struct zwlr_gamma_control_v1 *control;
static int gamma_applied;

static void registry_global(
    void *data,
    struct wl_registry *registry,
    uint32_t name,
    const char *interface,
    uint32_t version
) {
    if (strcmp(interface, wl_output_interface.name) == 0 && output == NULL) {
        output = wl_registry_bind(
            registry, name, &wl_output_interface, 1);
    } else if (strcmp(
        interface, zwlr_gamma_control_manager_v1_interface.name) == 0
    ) {
        manager = wl_registry_bind(
            registry, name, &zwlr_gamma_control_manager_v1_interface, 1);
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

/* Stages a ramp of `size` uint16_t triples (red, green, blue planes
 * back to back) into a temp file and hands its fd to set_gamma. The
 * fd is closed locally once the request is sent -- ownership of the
 * data passed via SCM_RIGHTS, not the descriptor itself. */
static void apply_warm_ramp(uint32_t size) {
    char path[] = "/tmp/gamma-smoke-XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0) {
        fprintf(stderr, "mkstemp: %s\n", strerror(errno));
        return;
    }
    unlink(path);

    size_t expected = (size_t) size * 3 * sizeof(uint16_t);
    if (ftruncate(fd, (off_t) expected) != 0) {
        fprintf(stderr, "ftruncate: %s\n", strerror(errno));
        close(fd);
        return;
    }

    uint16_t *table = malloc(expected);
    if (table == NULL) {
        close(fd);
        return;
    }

    uint32_t i;
    for (i = 0; i < size; i++) {
        double frac = (size > 1) ? ((double) i / (double) (size - 1)) : 0.0;
        uint16_t identity = (uint16_t) lround(frac * 65535.0);
        table[i] = identity;                  /* red   */
        table[size + i] = identity;           /* green */
        table[2 * size + i] = (uint16_t) lround(frac * 65535.0 * 0.8);
    }

    ssize_t written = write(fd, table, expected);
    free(table);
    if (written < 0 || (size_t) written != expected) {
        fprintf(stderr, "write: %s\n", strerror(errno));
        close(fd);
        return;
    }
    if (lseek(fd, 0, SEEK_SET) != 0) {
        fprintf(stderr, "lseek: %s\n", strerror(errno));
        close(fd);
        return;
    }

    zwlr_gamma_control_v1_set_gamma(control, fd);
    close(fd);
    gamma_applied = 1;
}

static void gamma_control_gamma_size(
    void *data,
    struct zwlr_gamma_control_v1 *control_,
    uint32_t size
) {
    printf("gamma_size: %u\n", size);
    apply_warm_ramp(size);
}

static void gamma_control_failed(
    void *data,
    struct zwlr_gamma_control_v1 *control_
) {
    fprintf(stderr, "gamma control failed\n");
    exit(1);
}

static const struct zwlr_gamma_control_v1_listener gamma_control_listener = {
    .gamma_size = gamma_control_gamma_size,
    .failed = gamma_control_failed
};

int main(void) {
    struct wl_display *display = wl_display_connect(NULL);
    if (display == NULL) {
        fprintf(stderr, "wl_display_connect failed\n");
        return 1;
    }

    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);

    if (output == NULL || manager == NULL) {
        fprintf(
            stderr,
            "missing wl_output or zwlr_gamma_control_manager_v1\n"
        );
        return 1;
    }

    control = zwlr_gamma_control_manager_v1_get_gamma_control(
        manager, output);
    zwlr_gamma_control_v1_add_listener(
        control, &gamma_control_listener, NULL);
    wl_display_roundtrip(display);

    if (!gamma_applied) {
        return 1;
    }

    printf("gamma applied, sleeping 5s before disconnect...\n");
    sleep(5);

    zwlr_gamma_control_v1_destroy(control);
    zwlr_gamma_control_manager_v1_destroy(manager);
    wl_display_disconnect(display);
    return 0;
}
