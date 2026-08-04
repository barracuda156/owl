# This file is part of Owl.
#
# owl-egl: client-side EGL over CGL + IOSurface. Mac-only, like the
# rest of owl; see HWGL.md at the repository root.
#
# Build:    make [PREFIX=/opt/local]
# Install:  make install [PREFIX=/opt/local] [DESTDIR=...]
#
# The library installs into $(PREFIX)/lib/owl-egl/ so it never
# collides with Mesa's libEGL; clients opt in at runtime with
#   DYLD_LIBRARY_PATH=$(PREFIX)/lib/owl-egl <client>
# (dyld overrides by leaf name, so no relinking is needed).
#
# EGL headers come from the installed mesa port, whose eglplatform.h
# carries the Apple pointer-native-types fix; this library implements
# that ABI.

PREFIX ?= /opt/local
CC ?= cc
PKG_CONFIG ?= pkg-config
WAYLAND_SCANNER ?= wayland-scanner
MIG ?= mig

PROTO = ../Sources/Protocol

LIB = libEGL.1.dylib
LIBDIR = $(PREFIX)/lib/owl-egl

CFLAGS ?= -O2 -g
CFLAGS += -Wall -std=gnu99 -mmacosx-version-min=10.6 -I. \
	$(shell $(PKG_CONFIG) --cflags wayland-client wayland-egl-backend egl)
LIBS = $(shell $(PKG_CONFIG) --libs wayland-client) \
	-framework OpenGL -framework IOSurface -framework CoreFoundation

SCANNER_HEADERS = \
	owl-mach-ipc-unstable-v1-client-protocol.h \
	owl-iosurface-unstable-v1-client-protocol.h
MIG_HEADERS = \
	owl-mach-ipc-unstable-v1-mig.h \
	owl-iosurface-unstable-v1-mig.h
GENERATED_HEADERS = $(SCANNER_HEADERS) $(MIG_HEADERS)

OBJS = \
	egl-core.o \
	egl-wayland.o \
	egl-mach.o \
	egl-fbzero.o \
	owl-mach-ipc-unstable-v1-protocol.o \
	owl-iosurface-unstable-v1-protocol.o \
	owl-mach-ipc-unstable-v1-mig-user.o \
	owl-iosurface-unstable-v1-mig-user.o

all: $(LIB)

$(LIB): $(OBJS)
	$(CC) -dynamiclib -o $@ $(OBJS) \
		-install_name $(LIBDIR)/$(LIB) \
		-compatibility_version 1 -current_version 1 \
		-mmacosx-version-min=10.6 \
		$(LIBS)
	ln -sf $(LIB) libEGL.dylib

%-client-protocol.h: $(PROTO)/%.xml
	$(WAYLAND_SCANNER) client-header $< $@

%-protocol.c: $(PROTO)/%.xml
	$(WAYLAND_SCANNER) private-code $< $@

# The MIG import of the -mig-types.h header ends up as an #include in
# the generated code; -I$(PROTO) on the compile lines resolves it.
owl-mach-ipc-unstable-v1-mig-user.c owl-mach-ipc-unstable-v1-mig.h: \
		$(PROTO)/owl-mach-ipc-unstable-v1-mig.defs
	$(MIG) -user owl-mach-ipc-unstable-v1-mig-user.c \
		-header owl-mach-ipc-unstable-v1-mig.h \
		-server /dev/null -sheader /dev/null $<

owl-iosurface-unstable-v1-mig-user.c owl-iosurface-unstable-v1-mig.h: \
		$(PROTO)/owl-iosurface-unstable-v1-mig.defs
	$(MIG) -user owl-iosurface-unstable-v1-mig-user.c \
		-header owl-iosurface-unstable-v1-mig.h \
		-server /dev/null -sheader /dev/null $<

%.o: %.c
	$(CC) $(CFLAGS) -I$(PROTO) -c -o $@ $<

egl-core.o egl-wayland.o egl-mach.o egl-fbzero.o: \
	owl-egl-private.h $(GENERATED_HEADERS)

install: $(LIB)
	mkdir -p $(DESTDIR)$(LIBDIR)
	cp $(LIB) $(DESTDIR)$(LIBDIR)/
	ln -sf $(LIB) $(DESTDIR)$(LIBDIR)/libEGL.dylib

clean:
	rm -f $(LIB) libEGL.dylib $(OBJS) \
		$(GENERATED_HEADERS) \
		owl-mach-ipc-unstable-v1-protocol.c \
		owl-iosurface-unstable-v1-protocol.c \
		owl-mach-ipc-unstable-v1-mig-user.c \
		owl-iosurface-unstable-v1-mig-user.c

.PHONY: all install clean
