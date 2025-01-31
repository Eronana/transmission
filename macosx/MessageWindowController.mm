/******************************************************************************
 * Copyright (c) 2006-2012 Transmission authors and contributors
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 *****************************************************************************/

#include <libtransmission/transmission.h>
#include <libtransmission/log.h>

#import "MessageWindowController.h"
#import "Controller.h"
#import "NSApplicationAdditions.h"
#import "NSMutableArrayAdditions.h"
#import "NSStringAdditions.h"

#define LEVEL_ERROR 0
#define LEVEL_INFO 1
#define LEVEL_DEBUG 2

#define UPDATE_SECONDS 0.75

@interface MessageWindowController (Private)

- (void)resizeColumn;
- (BOOL)shouldIncludeMessageForFilter:(NSString*)filterString message:(NSDictionary*)message;
- (void)updateListForFilter;
- (NSString*)stringForMessage:(NSDictionary*)message;

@end

@implementation MessageWindowController

- (instancetype)init
{
    return [super initWithWindowNibName:@"MessageWindow"];
}

- (void)awakeFromNib
{
    NSWindow* window = self.window;
    window.frameAutosaveName = @"MessageWindowFrame";
    [window setFrameUsingName:@"MessageWindowFrame"];
    window.restorationClass = [self class];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resizeColumn)
                                               name:NSTableViewColumnDidResizeNotification
                                             object:fMessageTable];

    [window setContentBorderThickness:NSMinY(fMessageTable.enclosingScrollView.frame) forEdge:NSMinYEdge];

    self.window.title = NSLocalizedString(@"Message Log", "Message window -> title");

    //set images and text for popup button items
    [fLevelButton itemAtIndex:LEVEL_ERROR].title = NSLocalizedString(@"Error", "Message window -> level string");
    [fLevelButton itemAtIndex:LEVEL_INFO].title = NSLocalizedString(@"Info", "Message window -> level string");
    [fLevelButton itemAtIndex:LEVEL_DEBUG].title = NSLocalizedString(@"Debug", "Message window -> level string");

    CGFloat const levelButtonOldWidth = NSWidth(fLevelButton.frame);
    [fLevelButton sizeToFit];

    //set table column text
    [fMessageTable tableColumnWithIdentifier:@"Date"].headerCell.title = NSLocalizedString(@"Date", "Message window -> table column");
    [fMessageTable tableColumnWithIdentifier:@"Name"].headerCell.title = NSLocalizedString(@"Process", "Message window -> table column");
    [fMessageTable tableColumnWithIdentifier:@"Message"].headerCell.title = NSLocalizedString(@"Message", "Message window -> table column");

    //set and size buttons
    fSaveButton.title = [NSLocalizedString(@"Save", "Message window -> save button") stringByAppendingEllipsis];
    [fSaveButton sizeToFit];

    NSRect saveButtonFrame = fSaveButton.frame;
    saveButtonFrame.size.width += 10.0;
    saveButtonFrame.origin.x += NSWidth(fLevelButton.frame) - levelButtonOldWidth;
    fSaveButton.frame = saveButtonFrame;

    CGFloat const oldClearButtonWidth = fClearButton.frame.size.width;

    fClearButton.title = NSLocalizedString(@"Clear", "Message window -> save button");
    [fClearButton sizeToFit];

    NSRect clearButtonFrame = fClearButton.frame;
    clearButtonFrame.size.width = MAX(clearButtonFrame.size.width + 10.0, saveButtonFrame.size.width);
    clearButtonFrame.origin.x -= NSWidth(clearButtonFrame) - oldClearButtonWidth;
    fClearButton.frame = clearButtonFrame;

    [fFilterField.cell setPlaceholderString:NSLocalizedString(@"Filter", "Message window -> filter field")];
    NSRect filterButtonFrame = fFilterField.frame;
    filterButtonFrame.origin.x -= NSWidth(clearButtonFrame) - oldClearButtonWidth;
    fFilterField.frame = filterButtonFrame;

    fAttributes = [[[fMessageTable tableColumnWithIdentifier:@"Message"].dataCell attributedStringValue] attributesAtIndex:0
                                                                                                            effectiveRange:NULL];

    //select proper level in popup button
    switch ([NSUserDefaults.standardUserDefaults integerForKey:@"MessageLevel"])
    {
    case TR_LOG_ERROR:
        [fLevelButton selectItemAtIndex:LEVEL_ERROR];
        break;
    case TR_LOG_INFO:
        [fLevelButton selectItemAtIndex:LEVEL_INFO];
        break;
    case TR_LOG_DEBUG:
        [fLevelButton selectItemAtIndex:LEVEL_DEBUG];
        break;
    default: //safety
        [NSUserDefaults.standardUserDefaults setInteger:TR_LOG_ERROR forKey:@"MessageLevel"];
        [fLevelButton selectItemAtIndex:LEVEL_ERROR];
    }

    fMessages = [[NSMutableArray alloc] init];
    fDisplayedMessages = [[NSMutableArray alloc] init];

    fLock = [[NSLock alloc] init];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [fTimer invalidate];
}

- (void)windowDidBecomeKey:(NSNotification*)notification
{
    if (!fTimer)
    {
        fTimer = [NSTimer scheduledTimerWithTimeInterval:UPDATE_SECONDS target:self selector:@selector(updateLog:) userInfo:nil
                                                 repeats:YES];
        [self updateLog:nil];
    }
}

- (void)windowWillClose:(id)sender
{
    [fTimer invalidate];
    fTimer = nil;
}

+ (void)restoreWindowWithIdentifier:(NSString*)identifier
                              state:(NSCoder*)state
                  completionHandler:(void (^)(NSWindow*, NSError*))completionHandler
{
    NSAssert1([identifier isEqualToString:@"MessageWindow"], @"Trying to restore unexpected identifier %@", identifier);

    NSWindow* window = ((Controller*)NSApp.delegate).messageWindowController.window;
    completionHandler(window, nil);
}

- (void)window:(NSWindow*)window didDecodeRestorableState:(NSCoder*)coder
{
    [fTimer invalidate];
    fTimer = [NSTimer scheduledTimerWithTimeInterval:UPDATE_SECONDS target:self selector:@selector(updateLog:) userInfo:nil
                                             repeats:YES];
    [self updateLog:nil];
}

- (void)updateLog:(NSTimer*)timer
{
    tr_log_message* messages;
    if ((messages = tr_logGetQueue()) == NULL)
    {
        return;
    }

    [fLock lock];

    static NSUInteger currentIndex = 0;

    NSScroller* scroller = fMessageTable.enclosingScrollView.verticalScroller;
    BOOL const shouldScroll = currentIndex == 0 || scroller.floatValue == 1.0 || scroller.hidden || scroller.knobProportion == 1.0;

    NSInteger const maxLevel = [NSUserDefaults.standardUserDefaults integerForKey:@"MessageLevel"];
    NSString* filterString = fFilterField.stringValue;

    BOOL changed = NO;

    for (tr_log_message* currentMessage = messages; currentMessage != NULL; currentMessage = currentMessage->next)
    {
        NSString* name = currentMessage->name != NULL ? @(currentMessage->name) : NSProcessInfo.processInfo.processName;

        NSString* file = [(@(currentMessage->file)).lastPathComponent stringByAppendingFormat:@":%d", currentMessage->line];

        NSDictionary* message = @{
            @"Message" : @(currentMessage->message),
            @"Date" : [NSDate dateWithTimeIntervalSince1970:currentMessage->when],
            @"Index" : @(currentIndex++), //more accurate when sorting by date
            @"Level" : @(currentMessage->level),
            @"Name" : name,
            @"File" : file
        };
        [fMessages addObject:message];

        if (currentMessage->level <= maxLevel && [self shouldIncludeMessageForFilter:filterString message:message])
        {
            [fDisplayedMessages addObject:message];
            changed = YES;
        }
    }

    if (fMessages.count > TR_LOG_MAX_QUEUE_LENGTH)
    {
        NSUInteger const oldCount = fDisplayedMessages.count;

        NSIndexSet* removeIndexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, fMessages.count - TR_LOG_MAX_QUEUE_LENGTH)];
        NSArray* itemsToRemove = [fMessages objectsAtIndexes:removeIndexes];

        [fMessages removeObjectsAtIndexes:removeIndexes];
        [fDisplayedMessages removeObjectsInArray:itemsToRemove];

        changed |= oldCount > fDisplayedMessages.count;
    }

    if (changed)
    {
        [fDisplayedMessages sortUsingDescriptors:fMessageTable.sortDescriptors];

        [fMessageTable reloadData];
        if (shouldScroll)
            [fMessageTable scrollRowToVisible:fMessageTable.numberOfRows - 1];
    }

    [fLock unlock];

    tr_logFreeQueue(messages);
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView
{
    return fDisplayedMessages.count;
}

- (id)tableView:(NSTableView*)tableView objectValueForTableColumn:(NSTableColumn*)column row:(NSInteger)row
{
    NSString* ident = column.identifier;
    NSDictionary* message = fDisplayedMessages[row];

    if ([ident isEqualToString:@"Date"])
    {
        return message[@"Date"];
    }
    else if ([ident isEqualToString:@"Level"])
    {
        NSInteger const level = [message[@"Level"] integerValue];
        switch (level)
        {
        case TR_LOG_ERROR:
            return [NSImage imageNamed:@"RedDotFlat"];
        case TR_LOG_INFO:
            return [NSImage imageNamed:@"YellowDotFlat"];
        case TR_LOG_DEBUG:
            return [NSImage imageNamed:@"PurpleDotFlat"];
        default:
            NSAssert1(NO, @"Unknown message log level: %ld", level);
            return nil;
        }
    }
    else if ([ident isEqualToString:@"Name"])
    {
        return message[@"Name"];
    }
    else
    {
        return message[@"Message"];
    }
}

#warning don't cut off end
- (CGFloat)tableView:(NSTableView*)tableView heightOfRow:(NSInteger)row
{
    NSString* message = fDisplayedMessages[row][@"Message"];

    NSTableColumn* column = [tableView tableColumnWithIdentifier:@"Message"];
    CGFloat const count = floorf([message sizeWithAttributes:fAttributes].width / column.width);

    return tableView.rowHeight * (count + 1.0);
}

- (void)tableView:(NSTableView*)tableView sortDescriptorsDidChange:(NSArray*)oldDescriptors
{
    [fDisplayedMessages sortUsingDescriptors:fMessageTable.sortDescriptors];
    [fMessageTable reloadData];
}

- (NSString*)tableView:(NSTableView*)tableView
        toolTipForCell:(NSCell*)cell
                  rect:(NSRectPointer)rect
           tableColumn:(NSTableColumn*)column
                   row:(NSInteger)row
         mouseLocation:(NSPoint)mouseLocation
{
    NSDictionary* message = fDisplayedMessages[row];
    return message[@"File"];
}

- (void)copy:(id)sender
{
    NSIndexSet* indexes = fMessageTable.selectedRowIndexes;
    NSMutableArray* messageStrings = [NSMutableArray arrayWithCapacity:indexes.count];

    for (NSDictionary* message in [fDisplayedMessages objectsAtIndexes:indexes])
    {
        [messageStrings addObject:[self stringForMessage:message]];
    }

    NSString* messageString = [messageStrings componentsJoinedByString:@"\n"];

    NSPasteboard* pb = NSPasteboard.generalPasteboard;
    [pb clearContents];
    [pb writeObjects:@[ messageString ]];
}

- (BOOL)validateMenuItem:(NSMenuItem*)menuItem
{
    SEL action = menuItem.action;

    if (action == @selector(copy:))
    {
        return fMessageTable.numberOfSelectedRows > 0;
    }

    return YES;
}

- (void)changeLevel:(id)sender
{
    NSInteger level;
    switch (fLevelButton.indexOfSelectedItem)
    {
    case LEVEL_ERROR:
        level = TR_LOG_ERROR;
        break;
    case LEVEL_INFO:
        level = TR_LOG_INFO;
        break;
    case LEVEL_DEBUG:
        level = TR_LOG_DEBUG;
        break;
    default:
        NSAssert1(NO, @"Unknown message log level: %ld", [fLevelButton indexOfSelectedItem]);
        level = TR_LOG_INFO;
    }

    if ([NSUserDefaults.standardUserDefaults integerForKey:@"MessageLevel"] == level)
    {
        return;
    }

    [NSUserDefaults.standardUserDefaults setInteger:level forKey:@"MessageLevel"];

    [fLock lock];

    [self updateListForFilter];

    [fLock unlock];
}

- (void)changeFilter:(id)sender
{
    [fLock lock];

    [self updateListForFilter];

    [fLock unlock];
}

- (void)clearLog:(id)sender
{
    [fLock lock];

    [fMessages removeAllObjects];

    [fMessageTable beginUpdates];
    [fMessageTable removeRowsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, fDisplayedMessages.count)]
                         withAnimation:NSTableViewAnimationSlideLeft];

    [fDisplayedMessages removeAllObjects];

    [fMessageTable endUpdates];

    [fLock unlock];
}

- (void)writeToFile:(id)sender
{
    NSSavePanel* panel = [NSSavePanel savePanel];
    panel.allowedFileTypes = @[ @"txt" ];
    panel.canSelectHiddenExtension = YES;

    panel.nameFieldStringValue = NSLocalizedString(@"untitled", "Save log panel -> default file name");

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSInteger result) {
        if (result == NSFileHandlingPanelOKButton)
        {
            //make the array sorted by date
            NSSortDescriptor* descriptor = [NSSortDescriptor sortDescriptorWithKey:@"Index" ascending:YES];
            NSArray* descriptors = @[ descriptor ];
            NSArray* sortedMessages = [fDisplayedMessages sortedArrayUsingDescriptors:descriptors];

            //create the text to output
            NSMutableArray* messageStrings = [NSMutableArray arrayWithCapacity:sortedMessages.count];
            for (NSDictionary* message in sortedMessages)
            {
                [messageStrings addObject:[self stringForMessage:message]];
            }

            NSString* fileString = [messageStrings componentsJoinedByString:@"\n"];

            if (![fileString writeToFile:panel.URL.path atomically:YES encoding:NSUTF8StringEncoding error:nil])
            {
                NSAlert* alert = [[NSAlert alloc] init];
                [alert addButtonWithTitle:NSLocalizedString(@"OK", "Save log alert panel -> button")];
                alert.messageText = NSLocalizedString(@"Log Could Not Be Saved", "Save log alert panel -> title");
                alert.informativeText = [NSString
                    stringWithFormat:NSLocalizedString(@"There was a problem creating the file \"%@\".", "Save log alert panel -> message"),
                                     panel.URL.path.lastPathComponent];
                alert.alertStyle = NSWarningAlertStyle;

                [alert runModal];
            }
        }
    }];
}

@end

@implementation MessageWindowController (Private)

- (void)resizeColumn
{
    [fMessageTable noteHeightOfRowsWithIndexesChanged:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, fMessageTable.numberOfRows)]];
}

- (BOOL)shouldIncludeMessageForFilter:(NSString*)filterString message:(NSDictionary*)message
{
    if ([filterString isEqualToString:@""])
    {
        return YES;
    }

    NSStringCompareOptions const searchOptions = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    return [message[@"Name"] rangeOfString:filterString options:searchOptions].location != NSNotFound ||
        [message[@"Message"] rangeOfString:filterString options:searchOptions].location != NSNotFound;
}

- (void)updateListForFilter
{
    NSInteger const level = [NSUserDefaults.standardUserDefaults integerForKey:@"MessageLevel"];
    NSString* filterString = fFilterField.stringValue;

    NSIndexSet* indexes = [fMessages indexesOfObjectsWithOptions:NSEnumerationConcurrent
                                                     passingTest:^BOOL(id message, NSUInteger idx, BOOL* stop) {
                                                         return [((NSDictionary*)message)[@"Level"] integerValue] <= level &&
                                                             [self shouldIncludeMessageForFilter:filterString message:message];
                                                     }];

    NSArray* tempMessages = [[fMessages objectsAtIndexes:indexes] sortedArrayUsingDescriptors:fMessageTable.sortDescriptors];

    [fMessageTable beginUpdates];

    //figure out which rows were added/moved
    NSUInteger currentIndex = 0, totalCount = 0;
    NSMutableArray* itemsToAdd = [NSMutableArray array];
    NSMutableIndexSet* itemsToAddIndexes = [NSMutableIndexSet indexSet];

    for (NSDictionary* message in tempMessages)
    {
        NSUInteger const previousIndex = [fDisplayedMessages
            indexOfObject:message
                  inRange:NSMakeRange(currentIndex, fDisplayedMessages.count - currentIndex)];
        if (previousIndex == NSNotFound)
        {
            [itemsToAdd addObject:message];
            [itemsToAddIndexes addIndex:totalCount];
        }
        else
        {
            if (previousIndex != currentIndex)
            {
                [fDisplayedMessages moveObjectAtIndex:previousIndex toIndex:currentIndex];
                [fMessageTable moveRowAtIndex:previousIndex toIndex:currentIndex];
            }
            ++currentIndex;
        }

        ++totalCount;
    }

    //remove trailing items - those are the unused
    if (currentIndex < fDisplayedMessages.count)
    {
        NSRange const removeRange = NSMakeRange(currentIndex, fDisplayedMessages.count - currentIndex);
        [fDisplayedMessages removeObjectsInRange:removeRange];
        [fMessageTable removeRowsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:removeRange]
                             withAnimation:NSTableViewAnimationSlideDown];
    }

    //add new items
    [fDisplayedMessages insertObjects:itemsToAdd atIndexes:itemsToAddIndexes];
    [fMessageTable insertRowsAtIndexes:itemsToAddIndexes withAnimation:NSTableViewAnimationSlideUp];

    [fMessageTable endUpdates];

    NSAssert2([fDisplayedMessages isEqualToArray:tempMessages], @"Inconsistency between message arrays! %@ %@", fDisplayedMessages, tempMessages);
}

- (NSString*)stringForMessage:(NSDictionary*)message
{
    NSString* levelString;
    NSInteger const level = [message[@"Level"] integerValue];
    switch (level)
    {
    case TR_LOG_ERROR:
        levelString = NSLocalizedString(@"Error", "Message window -> level");
        break;
    case TR_LOG_INFO:
        levelString = NSLocalizedString(@"Info", "Message window -> level");
        break;
    case TR_LOG_DEBUG:
        levelString = NSLocalizedString(@"Debug", "Message window -> level");
        break;
    default:
        NSAssert1(NO, @"Unknown message log level: %ld", level);
        levelString = @"?";
    }

    return [NSString
        stringWithFormat:@"%@ %@ [%@] %@: %@", message[@"Date"], message[@"File"], levelString, message[@"Name"], message[@"Message"], nil];
}

@end
