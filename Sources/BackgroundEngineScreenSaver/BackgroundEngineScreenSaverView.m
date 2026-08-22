#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenSaver/ScreenSaver.h>
#import <limits.h>
#import <pwd.h>
#import <unistd.h>

static void *BackgroundEnginePlayerItemStatusContext = &BackgroundEnginePlayerItemStatusContext;
static const unsigned long long BackgroundEngineMaximumImageSourceBytes = 256ULL * 1024ULL * 1024ULL;
static const unsigned long long BackgroundEngineMaximumDecodedFrameBytes = 256ULL * 1024ULL * 1024ULL;
static const size_t BackgroundEngineMaximumImageFrameCount = 10000;
static const size_t BackgroundEngineMaximumImageFrameDimension = 16384;
static const unsigned long long BackgroundEngineConservativeBytesPerPixel = 16ULL;

static BOOL BackgroundEngineImageDimensionsFitBudget(size_t width, size_t height) {
    if (width == 0 || height == 0
        || width > BackgroundEngineMaximumImageFrameDimension
        || height > BackgroundEngineMaximumImageFrameDimension
        || width > ULLONG_MAX / height) {
        return NO;
    }
    unsigned long long pixels = (unsigned long long)width * (unsigned long long)height;
    return pixels <= BackgroundEngineMaximumDecodedFrameBytes / BackgroundEngineConservativeBytesPerPixel;
}

static BOOL BackgroundEngineDecodedImageFitsBudget(CGImageRef image) {
    size_t height = CGImageGetHeight(image);
    size_t bytesPerRow = CGImageGetBytesPerRow(image);
    if (height == 0 || bytesPerRow == 0 || bytesPerRow > ULLONG_MAX / height) {
        return NO;
    }
    return (unsigned long long)bytesPerRow * (unsigned long long)height
        <= BackgroundEngineMaximumDecodedFrameBytes;
}

static CGImageSourceRef BackgroundEngineCreateValidatedImageSource(NSURL *url) {
    NSError *error = nil;
    NSDictionary<NSURLResourceKey, id> *values = [url resourceValuesForKeys:@[
        NSURLIsRegularFileKey,
        NSURLIsSymbolicLinkKey,
        NSURLFileSizeKey,
    ] error:&error];
    if (error || ![values[NSURLIsRegularFileKey] boolValue]
        || [values[NSURLIsSymbolicLinkKey] boolValue]
        || [values[NSURLFileSizeKey] unsignedLongLongValue] > BackgroundEngineMaximumImageSourceBytes) {
        return NULL;
    }
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, (__bridge CFDictionaryRef)@{
        (__bridge NSString *)kCGImageSourceShouldCache: @NO,
    });
    if (!source) {
        return NULL;
    }
    size_t frameCount = CGImageSourceGetCount(source);
    if (frameCount == 0 || frameCount > BackgroundEngineMaximumImageFrameCount) {
        CFRelease(source);
        return NULL;
    }
    return source;
}

static CGImageRef BackgroundEngineCreateValidatedImageAtIndex(CGImageSourceRef source, size_t index) {
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, index, NULL));
    size_t declaredWidth = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedLongLongValue];
    size_t declaredHeight = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedLongLongValue];
    if (!BackgroundEngineImageDimensionsFitBudget(declaredWidth, declaredHeight)) {
        return NULL;
    }
    size_t maximumPixelSize = MAX(declaredWidth, declaredHeight);
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, index, (__bridge CFDictionaryRef)@{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(maximumPixelSize),
        (__bridge NSString *)kCGImageSourceShouldAllowFloat: @NO,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES,
    });
    if (!image) {
        return NULL;
    }
    if (!BackgroundEngineImageDimensionsFitBudget(CGImageGetWidth(image), CGImageGetHeight(image))
        || !BackgroundEngineDecodedImageFitsBudget(image)) {
        CFRelease(image);
        return NULL;
    }
    return image;
}

@interface BackgroundEngineScreenSaverView : ScreenSaverView {
    CGImageSourceRef _imageSource;
    size_t _imageFrameCount;
    size_t _imageFrameIndex;
    CFTimeInterval _nextImageFrameTime;
}
@property(nonatomic, strong) AVPlayer *player;
@property(nonatomic, strong) AVPlayerLayer *playerLayer;
@property(nonatomic, strong) CALayer *imageLayer;
@property(nonatomic, strong) CATextLayer *fallbackLayer;
@property(nonatomic, strong) AVPlayerItem *observedPlayerItem;
@property(nonatomic, strong) id endObserver;
@property(nonatomic, strong) NSImage *fallbackImage;
@property(nonatomic, copy) NSString *fallbackDisplayMode;
@property(nonatomic, copy) NSString *fallbackMessage;
@end

@implementation BackgroundEngineScreenSaverView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        self.wantsLayer = YES;
        self.layer = [CALayer layer];
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        [self setAnimationTimeInterval:1.0 / 30.0];
        [self reloadContent];
    }
    return self;
}

- (void)dealloc {
    [self removeContent];
}

- (void)startAnimation {
    [super startAnimation];
    [self reloadContent];
    [self.player play];
}

- (void)stopAnimation {
    [self.player pause];
    [super stopAnimation];
}

- (void)animateOneFrame {
    [self advanceAnimatedImageIfNeeded];
    [self layoutContent];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self layoutContent];
}

- (void)reloadContent {
    NSDictionary *configuration = [self readConfiguration];
    if (![configuration[@"enabled"] boolValue]) {
        [self showFallbackMessage:@"Choose it in Wallpaper settings, then enable Screen Saver animation in Background Engine."];
        return;
    }

    NSString *displayMode = [configuration[@"displayMode"] isKindOfClass:NSString.class]
        ? configuration[@"displayMode"]
        : @"fit";
    NSString *sourcePath = [configuration[@"sourcePath"] isKindOfClass:NSString.class]
        ? configuration[@"sourcePath"]
        : nil;
    NSString *imagePath = [configuration[@"imagePath"] isKindOfClass:NSString.class]
        ? configuration[@"imagePath"]
        : nil;
    if (sourcePath != nil && [self canUseVideoAtPath:sourcePath]) {
        NSURL *fallbackImageURL = nil;
        if (imagePath != nil && [self canUseImageAtPath:imagePath]) {
            fallbackImageURL = [NSURL fileURLWithPath:imagePath];
        }
        NSURL *sourceURL = [NSURL fileURLWithPath:sourcePath];
        [self showVideoAtURL:sourceURL fallbackImageURL:fallbackImageURL displayMode:displayMode];
        return;
    }

    if (imagePath != nil && [self canUseImageAtPath:imagePath]) {
        [self showImageAtURL:[NSURL fileURLWithPath:imagePath] displayMode:displayMode];
        return;
    }

    [self showFallbackMessage:@"No playable Screen Saver media selected."];
}

- (NSDictionary *)readConfiguration {
    for (NSURL *configurationURL in [self configurationURLs]) {
        NSData *data = [NSData dataWithContentsOfURL:configurationURL];
        if (!data) {
            continue;
        }
        NSDictionary *configuration = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([configuration isKindOfClass:NSDictionary.class]) {
            return configuration;
        }
    }
    return @{};
}

- (NSArray<NSURL *> *)configurationURLs {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSURL *realHomeApplicationSupport = [self realHomeApplicationSupportURL];
    if (realHomeApplicationSupport) {
        [urls addObject:[self configurationURLFromApplicationSupport:realHomeApplicationSupport]];
    }

    NSURL *applicationSupport = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                                      inDomains:NSUserDomainMask].firstObject;
    if (applicationSupport) {
        NSURL *containerURL = [self configurationURLFromApplicationSupport:applicationSupport];
        if (![urls containsObject:containerURL]) {
            [urls addObject:containerURL];
        }
    }
    return urls;
}

- (NSURL *)configurationURLFromApplicationSupport:(NSURL *)applicationSupport {
    return [[[applicationSupport URLByAppendingPathComponent:@"Background Engine"]
        URLByAppendingPathComponent:@"LockScreen"] URLByAppendingPathComponent:@"active.json"];
}

- (NSURL *)realHomeApplicationSupportURL {
    struct passwd *password = getpwuid(getuid());
    if (!password || !password->pw_dir) {
        return nil;
    }
    NSString *homePath = [NSString stringWithUTF8String:password->pw_dir];
    if (homePath.length == 0) {
        return nil;
    }
    return [[NSURL fileURLWithPath:homePath] URLByAppendingPathComponent:@"Library/Application Support"];
}

- (BOOL)canUseVideoAtPath:(NSString *)path {
    if (path.length == 0) {
        return NO;
    }
    NSDictionary<NSFileAttributeKey, id> *attributes =
        [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    return [attributes[NSFileType] isEqualToString:NSFileTypeRegular];
}

- (BOOL)canUseImageAtPath:(NSString *)path {
    if (path.length == 0) {
        return NO;
    }
    CGImageSourceRef source = BackgroundEngineCreateValidatedImageSource([NSURL fileURLWithPath:path]);
    if (!source) {
        return NO;
    }
    CFRelease(source);
    return YES;
}

- (void)showVideoAtURL:(NSURL *)url fallbackImageURL:(NSURL *)fallbackImageURL displayMode:(NSString *)displayMode {
    [self removeContent];
    BOOL hasFallbackImage = fallbackImageURL != nil;
    if (hasFallbackImage) {
        [self showImageAtURL:fallbackImageURL displayMode:displayMode];
    }

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    self.player = [AVPlayer playerWithPlayerItem:item];
    self.player.muted = YES;
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndNone;

    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    self.playerLayer.backgroundColor = NSColor.clearColor.CGColor;
    self.playerLayer.opaque = NO;
    self.playerLayer.hidden = hasFallbackImage;
    self.playerLayer.videoGravity = [self videoGravityForDisplayMode:displayMode];
    [self.layer addSublayer:self.playerLayer];
    [self layoutContent];
    if (hasFallbackImage) {
        self.observedPlayerItem = item;
        [item addObserver:self
               forKeyPath:@"status"
                  options:NSKeyValueObservingOptionNew
                  context:BackgroundEnginePlayerItemStatusContext];
        if (item.status == AVPlayerItemStatusReadyToPlay) {
            [self revealVideoPlayback];
        }
    }

    __weak typeof(self) weakSelf = self;
    self.endObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                                       object:item
                                                                        queue:NSOperationQueue.mainQueue
                                                                   usingBlock:^(__unused NSNotification *notification) {
        [item seekToTime:kCMTimeZero completionHandler:^(__unused BOOL finished) {
            [weakSelf.player play];
        }];
    }];
    [self.player play];
}

- (void)revealVideoPlayback {
    self.playerLayer.hidden = NO;
    [self.player play];
}

- (void)showImageAtURL:(NSURL *)url displayMode:(NSString *)displayMode {
    [self removeContent];
    CGImageSourceRef source = BackgroundEngineCreateValidatedImageSource(url);
    CGImageRef cgImage = source ? BackgroundEngineCreateValidatedImageAtIndex(source, 0) : NULL;
    if (!source || !cgImage) {
        if (source) {
            CFRelease(source);
        }
        // The configuration pointed at a path that exists on disk but could
        // not actually be decoded here (e.g. the legacy Screen Saver host
        // could not read its bytes). Previously this fell through silently,
        // leaving a solid black screen with no indication anything was
        // wrong; surface the failure instead so it is diagnosable.
        [self showFallbackMessage:[NSString stringWithFormat:@"Could not load the wallpaper image at %@.", url.path]];
        return;
    }
    _imageSource = source;
    _imageFrameCount = CGImageSourceGetCount(source);
    _imageFrameIndex = 0;
    self.fallbackDisplayMode = displayMode;
    self.fallbackMessage = nil;
    self.layer.contentsGravity = [self contentsGravityForDisplayMode:displayMode];
    self.imageLayer = [CALayer layer];
    self.imageLayer.contentsGravity = [self contentsGravityForDisplayMode:displayMode];
    self.imageLayer.backgroundColor = NSColor.blackColor.CGColor;
    [self.layer addSublayer:self.imageLayer];
    [self displayImage:cgImage];
    CFRelease(cgImage);
    _nextImageFrameTime = CACurrentMediaTime() + [self animatedImageFrameDurationAtIndex:0];
    [self layoutContent];
}

- (void)displayImage:(CGImageRef)image {
    if (!image) {
        return;
    }
    NSSize size = NSMakeSize((CGFloat)CGImageGetWidth(image), (CGFloat)CGImageGetHeight(image));
    self.fallbackImage = [[NSImage alloc] initWithCGImage:image size:size];
    self.layer.contents = (__bridge id)image;
    self.imageLayer.contents = (__bridge id)image;
    [self setNeedsDisplay:YES];
}

- (void)advanceAnimatedImageIfNeeded {
    if (!_imageSource || _imageFrameCount <= 1) {
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (_nextImageFrameTime <= 0.0) {
        _nextImageFrameTime = now + [self animatedImageFrameDurationAtIndex:_imageFrameIndex];
        return;
    }
    if (now < _nextImageFrameTime) {
        return;
    }

    NSUInteger advances = 0;
    do {
        _imageFrameIndex = (_imageFrameIndex + 1) % _imageFrameCount;
        CGImageRef image = BackgroundEngineCreateValidatedImageAtIndex(_imageSource, _imageFrameIndex);
        if (!image) {
            CFRelease(_imageSource);
            _imageSource = NULL;
            _imageFrameCount = 0;
            _nextImageFrameTime = 0.0;
            return;
        }
        [self displayImage:image];
        CFRelease(image);
        _nextImageFrameTime += [self animatedImageFrameDurationAtIndex:_imageFrameIndex];
        advances += 1;
    } while (now >= _nextImageFrameTime && advances < 5);

    if (now >= _nextImageFrameTime) {
        _nextImageFrameTime = now + [self animatedImageFrameDurationAtIndex:_imageFrameIndex];
    }
}

- (NSTimeInterval)animatedImageFrameDurationAtIndex:(size_t)index {
    if (!_imageSource || index >= _imageFrameCount) {
        return 0.1;
    }
    NSDictionary *properties = CFBridgingRelease(
        CGImageSourceCopyPropertiesAtIndex(_imageSource, index, NULL)
    );
    for (NSString *suffix in @[@"UnclampedDelayTime", @"DelayTime", @"FrameDelay"]) {
        NSNumber *number = [self firstNumberInValue:properties matchingKeySuffix:suffix];
        if (number.doubleValue > 0.0) {
            return MAX(1.0 / 60.0, number.doubleValue);
        }
    }
    return 0.1;
}

- (NSNumber *)firstNumberInValue:(id)value matchingKeySuffix:(NSString *)suffix {
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = value;
        for (id key in dictionary) {
            if ([[key description] hasSuffix:suffix] && [dictionary[key] isKindOfClass:NSNumber.class]) {
                return dictionary[key];
            }
        }
        for (id child in dictionary.allValues) {
            NSNumber *number = [self firstNumberInValue:child matchingKeySuffix:suffix];
            if (number != nil) {
                return number;
            }
        }
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id child in value) {
            NSNumber *number = [self firstNumberInValue:child matchingKeySuffix:suffix];
            if (number != nil) {
                return number;
            }
        }
    }
    return nil;
}

- (void)removeContent {
    if (_imageSource) {
        CFRelease(_imageSource);
        _imageSource = NULL;
    }
    _imageFrameCount = 0;
    _imageFrameIndex = 0;
    _nextImageFrameTime = 0.0;
    if (self.observedPlayerItem) {
        [self.observedPlayerItem removeObserver:self
                                     forKeyPath:@"status"
                                        context:BackgroundEnginePlayerItemStatusContext];
        self.observedPlayerItem = nil;
    }
    if (self.endObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:self.endObserver];
        self.endObserver = nil;
    }
    [self.player pause];
    self.player = nil;
    [self.playerLayer removeFromSuperlayer];
    self.playerLayer = nil;
    [self.imageLayer removeFromSuperlayer];
    self.imageLayer = nil;
    [self.fallbackLayer removeFromSuperlayer];
    self.fallbackLayer = nil;
    self.layer.contents = nil;
    self.fallbackImage = nil;
    self.fallbackDisplayMode = nil;
    self.fallbackMessage = nil;
    [self setNeedsDisplay:YES];
}

- (void)layoutContent {
    self.layer.frame = self.bounds;
    self.playerLayer.frame = self.bounds;
    self.imageLayer.frame = self.bounds;
    self.fallbackLayer.frame = NSInsetRect(self.bounds, 32.0, 32.0);
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)rect {
    [NSColor.blackColor setFill];
    NSRectFill(rect);

    if (self.fallbackImage) {
        NSRect imageRect = [self fallbackImageRectForImageSize:self.fallbackImage.size displayMode:self.fallbackDisplayMode];
        [self.fallbackImage drawInRect:imageRect
                              fromRect:NSZeroRect
                             operation:NSCompositingOperationSourceOver
                              fraction:1.0
                        respectFlipped:YES
                                 hints:nil];
        return;
    }

    if (self.fallbackMessage.length == 0) {
        return;
    }

    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    paragraphStyle.alignment = NSTextAlignmentCenter;
    NSDictionary<NSAttributedStringKey, id> *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:22.0 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
        NSParagraphStyleAttributeName: paragraphStyle,
    };
    NSRect textRect = NSInsetRect(self.bounds, 32.0, 32.0);
    [self.fallbackMessage drawInRect:textRect withAttributes:attributes];
}

- (NSRect)fallbackImageRectForImageSize:(NSSize)imageSize displayMode:(NSString *)displayMode {
    NSRect bounds = self.bounds;
    if ([displayMode isEqualToString:@"stretch"] || imageSize.width <= 0.0 || imageSize.height <= 0.0) {
        return bounds;
    }

    CGFloat widthRatio = NSWidth(bounds) / imageSize.width;
    CGFloat heightRatio = NSHeight(bounds) / imageSize.height;
    CGFloat scale = [displayMode isEqualToString:@"fill"] ? MAX(widthRatio, heightRatio) : MIN(widthRatio, heightRatio);
    NSSize scaledSize = NSMakeSize(imageSize.width * scale, imageSize.height * scale);
    return NSMakeRect(NSMidX(bounds) - scaledSize.width / 2.0,
                      NSMidY(bounds) - scaledSize.height / 2.0,
                      scaledSize.width,
                      scaledSize.height);
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (context == BackgroundEnginePlayerItemStatusContext) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (object != self.observedPlayerItem) {
                return;
            }
            if (self.observedPlayerItem.status == AVPlayerItemStatusReadyToPlay) {
                [self revealVideoPlayback];
            }
            if (self.observedPlayerItem.status == AVPlayerItemStatusFailed) {
                self.playerLayer.hidden = YES;
            }
        });
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)showFallbackMessage:(NSString *)message {
    [self removeContent];
    self.fallbackImage = nil;
    self.fallbackDisplayMode = nil;
    self.fallbackMessage = [NSString stringWithFormat:@"Background Engine\n%@", message];
    self.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.08 alpha:1.0].CGColor;
    self.fallbackLayer = [CATextLayer layer];
    self.fallbackLayer.string = self.fallbackMessage;
    self.fallbackLayer.alignmentMode = kCAAlignmentCenter;
    self.fallbackLayer.foregroundColor = NSColor.secondaryLabelColor.CGColor;
    self.fallbackLayer.fontSize = 22.0;
    self.fallbackLayer.wrapped = YES;
    self.fallbackLayer.contentsScale = [self backingScaleFactor];
    [self.layer addSublayer:self.fallbackLayer];
    [self layoutContent];
}

- (CGFloat)backingScaleFactor {
    CGFloat scale = self.window.screen.backingScaleFactor;
    if (scale > 0.0) {
        return scale;
    }
    return 1.0;
}

- (AVLayerVideoGravity)videoGravityForDisplayMode:(NSString *)displayMode {
    if ([displayMode isEqualToString:@"fill"]) {
        return AVLayerVideoGravityResizeAspectFill;
    }
    if ([displayMode isEqualToString:@"stretch"]) {
        return AVLayerVideoGravityResize;
    }
    return AVLayerVideoGravityResizeAspect;
}

- (CALayerContentsGravity)contentsGravityForDisplayMode:(NSString *)displayMode {
    if ([displayMode isEqualToString:@"fill"]) {
        return kCAGravityResizeAspectFill;
    }
    if ([displayMode isEqualToString:@"stretch"]) {
        return kCAGravityResize;
    }
    return kCAGravityResizeAspect;
}

@end
