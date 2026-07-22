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

#ifdef OWL_HAS_GCD

#import "OwlMIG.h"
#import <stdlib.h>


@implementation OwlMIG

// Use the function-based libdispatch API rather than the
// block-based one: blocks are unavailable in FSF GCC, while
// dispatch_source_set_event_handler_f() works everywhere
// libdispatch itself does (10.6+).
struct owl_mig_server_context {
    dispatch_source_t source;
    dispatch_mig_callback_t callback;
    size_t maxSize;
};

static void owl_mig_handle_event(void *context) {
    struct owl_mig_server_context *ctx = context;
    dispatch_mig_server(ctx->source, ctx->maxSize, ctx->callback);
}

+ (void) serveOnPort: (mach_port_t) port
       usingCallback: (dispatch_mig_callback_t)
    callback maxSize: (size_t) maxSize
{
    dispatch_source_t source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_MACH_RECV,
        port,
        0,
        dispatch_get_main_queue()
    );

    struct owl_mig_server_context *context =
        malloc(sizeof(struct owl_mig_server_context));
    context->source = source;
    context->callback = callback;
    context->maxSize = maxSize;

    dispatch_set_context(source, context);
    dispatch_source_set_event_handler_f(source, owl_mig_handle_event);
    dispatch_source_set_cancel_handler_f(source, free);
    dispatch_resume(source);
}

@end

#endif /* OWL_HAS_GCD */
