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
#import "OwlDataSource.h"


// A data source representing the content of a Cocoa drag session,
// e.g. files dragged in from the Finder (offered as text/uri-list)
// or a piece of text.
//
// Unlike OwlPasteboardDataSource, the content is snapshotted at
// creation time: the client asks for the data asynchronously,
// typically only after the drop, when the drag pasteboard may
// have already been cleared.
@interface OwlDragDataSource : OwlDataSource {
    NSData *_uriListData;
    NSData *_textData;
}

- (id) initWithPasteboard: (NSPasteboard *) pboard;

@end
