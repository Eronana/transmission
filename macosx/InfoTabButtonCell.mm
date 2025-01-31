/******************************************************************************
 * Copyright (c) 2007-2012 Transmission authors and contributors
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

#import "InfoTabButtonCell.h"
#import "NSApplicationAdditions.h"

@implementation InfoTabButtonCell

- (void)awakeFromNib
{
    if (!NSApp.onMojaveOrBetter)
    {
        NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(updateControlTint:) name:NSControlTintDidChangeNotification object:NSApp];
    }

    fSelected = NO;

    //expects the icon to currently be set as the image
    fIcon = self.image;
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setControlView:(NSView*)controlView
{
    BOOL const hadControlView = self.controlView != nil;

    super.controlView = controlView;

    if (!hadControlView)
    {
        [(NSMatrix*)self.controlView setToolTip:self.title forCell:self];
        [self setSelectedTab:fSelected];
    }
}

- (void)setSelectedTab:(BOOL)selected
{
    fSelected = selected;

    [self reloadAppearance];
}

- (void)reloadAppearance
{
    if (self.controlView == nil)
    {
        return;
    }

    NSInteger row, col;
    [(NSMatrix*)self.controlView getRow:&row column:&col ofCell:self];
    NSRect tabRect = [(NSMatrix*)self.controlView cellFrameAtRow:row column:col];
    tabRect.origin.x = 0.0;
    tabRect.origin.y = 0.0;

    NSImage* tabImage = [[NSImage alloc] initWithSize:tabRect.size];

    [tabImage lockFocus];

    NSGradient* gradient;
    if (fSelected)
    {
        NSColor *lightColor, *darkColor;
        if (@available(macOS 10.14, *))
        {
            lightColor = [NSColor.controlAccentColor blendedColorWithFraction:0.35 ofColor:NSColor.whiteColor];
            darkColor = [NSColor.controlAccentColor blendedColorWithFraction:0.15 ofColor:NSColor.whiteColor];
        }
        else
        {
            lightColor = [NSColor colorForControlTint:NSColor.currentControlTint];
            darkColor = [lightColor blendedColorWithFraction:0.2 ofColor:NSColor.blackColor];
        }
        gradient = [[NSGradient alloc] initWithStartingColor:lightColor endingColor:darkColor];
    }
    else
    {
        if (NSApp.isDarkMode)
        {
            NSColor* darkColor = [NSColor colorWithCalibratedRed:60.0 / 255.0 green:60.0 / 255.0 blue:60.0 / 255.0 alpha:1.0];
            NSColor* lightColor = [NSColor colorWithCalibratedRed:90.0 / 255.0 green:90.0 / 255.0 blue:90.0 / 255.0 alpha:1.0];
            gradient = [[NSGradient alloc] initWithStartingColor:lightColor endingColor:darkColor];
        }
        else
        {
            NSColor* lightColor = [NSColor colorWithCalibratedRed:245.0 / 255.0 green:245.0 / 255.0 blue:245.0 / 255.0 alpha:1.0];
            NSColor* darkColor = [NSColor colorWithCalibratedRed:215.0 / 255.0 green:215.0 / 255.0 blue:215.0 / 255.0 alpha:1.0];
            gradient = [[NSGradient alloc] initWithStartingColor:lightColor endingColor:darkColor];
        }
    }

    if (@available(macOS 10.14, *))
    {
        [NSColor.separatorColor set];
    }
    else
    {
        [NSColor.grayColor set];
    }
    NSRectFill(NSMakeRect(0.0, 0.0, NSWidth(tabRect), 1.0));
    NSRectFill(NSMakeRect(0.0, NSHeight(tabRect) - 1.0, NSWidth(tabRect), 1.0));
    NSRectFill(NSMakeRect(NSWidth(tabRect) - 1.0, 1.0, NSWidth(tabRect) - 1.0, NSHeight(tabRect) - 2.0));

    tabRect = NSMakeRect(0.0, 1.0, NSWidth(tabRect) - 1.0, NSHeight(tabRect) - 2.0);

    [gradient drawInRect:tabRect angle:270.0];

    if (fIcon)
    {
        NSSize const iconSize = fIcon.size;

        NSRect const iconRect = NSMakeRect(
            NSMinX(tabRect) + floor((NSWidth(tabRect) - iconSize.width) * 0.5),
            NSMinY(tabRect) + floor((NSHeight(tabRect) - iconSize.height) * 0.5),
            iconSize.width,
            iconSize.height);

        [fIcon drawInRect:iconRect fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
    }

    [tabImage unlockFocus];

    self.image = tabImage;
}

- (void)updateControlTint:(NSNotification*)notification
{
    NSAssert(!NSApp.onMojaveOrBetter, @"should not be observing control tint color when accent color is available");

    if (fSelected)
    {
        [self setSelectedTab:YES];
    }
}

@end
