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

#import "OwlSurfaceState.h"
#import "OwlBuffer.h"


@implementation OwlSurfaceState

- (id) init {
    _callbacks = [NSMutableArray new];
    _presentationFeedbacks = [NSMutableArray new];
    _damage = [NSMutableArray new];
    return self;
}

// Make a new state to succeed the given previous state.
//
// This copies over parts of the previous state that should
// be copied over, namely the attached buffer and geometry,
// and initializes other state to empty values.
- (id) initWithPreviousState: (OwlSurfaceState *) previousState {
    self = [self init];
    _buffer = [previousState->_buffer retain];
    _geometry = previousState->_geometry;
    _inputRegion = [previousState->_inputRegion retain];
    _viewportSourceIsSet = previousState->_viewportSourceIsSet;
    _viewportSource = previousState->_viewportSource;
    _viewportDestinationIsSet = previousState->_viewportDestinationIsSet;
    _viewportDestination = previousState->_viewportDestination;
    return self;
}

- (void) dealloc {
    [_buffer release];
    [_callbacks release];
    [_presentationFeedbacks release];
    [_damage release];
    [_inputRegion release];
    [super dealloc];
}

- (OwlBuffer *) buffer {
    return _buffer;
}

- (void) setBuffer: (OwlBuffer *) buffer {
    [buffer retain];
    [_buffer release];
    _buffer = buffer;
}

- (NSArray *) callbacks {
    return _callbacks;
}

- (void) addCallback: (OwlCallback *) callback {
    [_callbacks addObject: callback];
}

- (NSArray *) presentationFeedbacks {
    return _presentationFeedbacks;
}

- (void) addPresentationFeedback: (OwlWpPresentationFeedback *) feedback {
    [_presentationFeedbacks addObject: feedback];
}

- (NSArray *) damage {
    return _damage;
}

- (void) addDamage: (NSRect) damageRect {
    NSValue *value = [NSValue valueWithRect: damageRect];
    [_damage addObject: value];
}

- (NSRect) geometry {
    return _geometry;
}

- (void) setGeometry: (NSRect) geometry {
    _geometry = geometry;
}

- (NSData *) inputRegion {
    return _inputRegion;
}

- (void) setInputRegion: (NSData *) inputRegion {
    [inputRegion retain];
    [_inputRegion release];
    _inputRegion = inputRegion;
}

- (BOOL) viewportSourceIsSet {
    return _viewportSourceIsSet;
}

- (NSRect) viewportSource {
    return _viewportSource;
}

- (void) setViewportSource: (NSRect) source {
    _viewportSourceIsSet = YES;
    _viewportSource = source;
}

- (void) unsetViewportSource {
    _viewportSourceIsSet = NO;
    _viewportSource = NSZeroRect;
}

- (BOOL) viewportDestinationIsSet {
    return _viewportDestinationIsSet;
}

- (NSSize) viewportDestination {
    return _viewportDestination;
}

- (void) setViewportDestination: (NSSize) destination {
    _viewportDestinationIsSet = YES;
    _viewportDestination = destination;
}

- (void) unsetViewportDestination {
    _viewportDestinationIsSet = NO;
    _viewportDestination = NSZeroSize;
}

- (BOOL) hasSameViewportAs: (OwlSurfaceState *) other {
    if (_viewportSourceIsSet != other->_viewportSourceIsSet) {
        return NO;
    }
    if (_viewportSourceIsSet
        && !NSEqualRects(_viewportSource, other->_viewportSource)) {
        return NO;
    }
    if (_viewportDestinationIsSet != other->_viewportDestinationIsSet) {
        return NO;
    }
    if (_viewportDestinationIsSet
        && !NSEqualSizes(_viewportDestination,
                         other->_viewportDestination)) {
        return NO;
    }
    return YES;
}

@end
