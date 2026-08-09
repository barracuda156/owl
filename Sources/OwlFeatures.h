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

#ifdef __APPLE__
    #define OWL_PLATFORM_APPLE
    #include <AvailabilityMacros.h>
    /*
     * Grand Central Dispatch (libdispatch) and IOSurface were introduced
     * in Mac OS X 10.6 (Snow Leopard). On 10.5 (Leopard), we disable
     * these features and fall back to SHM-only buffer support.
     *
     * Note: the GCD code must stick to the function-based libdispatch
     * API (dispatch_source_set_event_handler_f() and friends), never
     * the block-based one; FSF GCC does not support blocks.
     */
    #if MAC_OS_X_VERSION_MAX_ALLOWED >= 1060
        #define OWL_HAS_GCD 1
        #define OWL_HAS_IOSURFACE 1
        /* IOPMAssertionCreateWithName (IOKit power management) is
         * also a 10.6+ API; on 10.5 idle-inhibit falls back to
         * periodic UpdateSystemActivity() calls. */
        #define OWL_HAS_IOPM 1
    #else
        #undef OWL_HAS_GCD
        #undef OWL_HAS_IOSURFACE
        #undef OWL_HAS_IOPM
    #endif
#else
    #undef OWL_PLATFORM_APPLE
    #undef OWL_HAS_GCD
    #undef OWL_HAS_IOSURFACE
    #undef OWL_HAS_IOPM
#endif

#ifdef GS_API_VERSION
    #define OWL_PLATFORM_GNUSTEP
#else
    #undef OWL_PLATFORM_GNUSTEP
#endif
