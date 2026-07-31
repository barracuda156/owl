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

#import "OwlDragDataSource.h"


@implementation OwlDragDataSource

- (id) initWithPasteboard: (NSPasteboard *) pboard {
    self = [super initWithResource: NULL];

    // Copy the types array first; see OwlPasteboardDataSource.
    NSArray *types = [NSArray arrayWithArray: [pboard types]];
    NSString *text = nil;

    if ([types containsObject: NSFilenamesPboardType]) {
        NSArray *paths = [pboard propertyListForType: NSFilenamesPboardType];
        NSMutableString *uriList = [NSMutableString string];
        for (NSString *path in paths) {
            NSURL *url = [NSURL fileURLWithPath: path];
            [uriList appendString: [url absoluteString]];
            // text/uri-list requires CRLF line breaks (RFC 2483).
            [uriList appendString: @"\r\n"];
        }
        if ([uriList length] > 0) {
            _uriListData = [[uriList dataUsingEncoding:
                                         NSUTF8StringEncoding] retain];
            [_mimeTypes addObject: @"text/uri-list"];
            // Fall back to the bare paths for text-only clients.
            text = [paths componentsJoinedByString: @"\n"];
        }
    }

    if ([types containsObject: NSStringPboardType]) {
        // Actual dragged text wins over the path fallback.
        text = [pboard stringForType: NSStringPboardType];
    }

    if (text != nil) {
        _textData = [[text dataUsingEncoding: NSUTF8StringEncoding] retain];
        [_mimeTypes addObject: @"text/plain;charset=utf-8"];
        [_mimeTypes addObject: @"text/plain"];
        [_mimeTypes addObject: @"UTF8_STRING"];
    }

    return self;
}

- (void) dealloc {
    [_uriListData release];
    [_textData release];
    [super dealloc];
}

- (void) sendContentOfMimeType: (NSString *) mimeType
                  toFileHandle: (NSFileHandle *) fileHandle
{
    NSData *data;
    if ([mimeType isEqual: @"text/uri-list"]) {
        data = _uriListData;
    } else {
        data = _textData;
    }
    if (data != nil) {
        [fileHandle writeData: data];
    }
}

- (void) sendCancelled {
    // Do nothing: the data lives on our side, there is no client
    // to notify.
}

@end
