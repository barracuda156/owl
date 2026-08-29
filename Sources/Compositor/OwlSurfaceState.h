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

#import <Cocoa/Cocoa.h>

@class OwlBuffer;
@class OwlCallback;
@class OwlWpPresentationFeedback;

@interface OwlSurfaceState : NSObject {
    OwlBuffer *_buffer;
    // TODO: dx, dy
    NSMutableArray *_callbacks;
    NSMutableArray *_presentationFeedbacks;
    NSMutableArray *_damage;
    NSRect _geometry;
    // The input region as an OwlRegion op list snapshot, or nil
    // when the whole surface accepts input (the default).
    NSData *_inputRegion;
    // wp_viewport crop and scale state: the source rectangle to
    // sample, in buffer coordinates (top-left origin), and the
    // destination size the surface gets, in surface coordinates.
    // Either one may be unset independently.
    BOOL _viewportSourceIsSet;
    NSRect _viewportSource;
    BOOL _viewportDestinationIsSet;
    NSSize _viewportDestination;
    // The wp_alpha_modifier_surface_v1 multiplier, 1.0 when none
    // is in effect.
    double _alphaMultiplier;
    // Whether an ext_background_effect_surface_v1 currently wants
    // its background blurred, reduced from the requested region to
    // a plain on/off (see OwlExtBackgroundEffectManagerV1.m).
    BOOL _blurEnabled;
}

- (id) init;
- (id) initWithPreviousState: (OwlSurfaceState *) previousState;

- (OwlBuffer *) buffer;
- (void) setBuffer: (OwlBuffer *) buffer;

- (NSArray *) callbacks;
- (void) addCallback: (OwlCallback *) callback;

- (NSArray *) presentationFeedbacks;
- (void) addPresentationFeedback: (OwlWpPresentationFeedback *) feedback;

- (NSArray *) damage;
- (void) addDamage: (NSRect) damageRect;

- (NSRect) geometry;
- (void) setGeometry: (NSRect) geometry;

- (NSData *) inputRegion;
- (void) setInputRegion: (NSData *) inputRegion;

- (BOOL) viewportSourceIsSet;
- (NSRect) viewportSource;
- (void) setViewportSource: (NSRect) source;
- (void) unsetViewportSource;

- (BOOL) viewportDestinationIsSet;
- (NSSize) viewportDestination;
- (void) setViewportDestination: (NSSize) destination;
- (void) unsetViewportDestination;

- (double) alphaMultiplier;
- (void) setAlphaMultiplier: (double) alphaMultiplier;

- (BOOL) blurEnabled;
- (void) setBlurEnabled: (BOOL) blurEnabled;

/* Whether the two states crop and scale identically; when they do
 * not, the same buffer maps onto the view differently, so damage
 * tracking is moot and the view needs a full repaint. */
- (BOOL) hasSameViewportAs: (OwlSurfaceState *) other;

@end
