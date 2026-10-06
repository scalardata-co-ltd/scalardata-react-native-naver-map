//
//  RNCNaverMapMarker.m
//  mj-studio-react-native-naver-map
//
//  Created by mj on 4/6/24.
//

#import "RNCNaverMapMarker.h"
#import "RNCNaverMapUtil.h"
#ifdef RCT_NEW_ARCH_ENABLED
using namespace facebook::react;
@interface RNCNaverMapMarker () <RCTRNCNaverMapMarkerViewProtocol>

@end
#endif

@implementation RNCNaverMapMarker {
  RNCNaverMapImageCanceller _imageCanceller;
  BOOL _isImageSetFromSubview;
  // Whether an icon (from the image prop or a custom view) has been applied to the marker.
  // Until then the marker is kept transparent so that the SDK default icon is never visible.
  BOOL _isIconReady;
  // Alpha requested by the `alpha` prop. `_inner.alpha` is this value only when the icon is ready.
  CGFloat _alpha;
  // Incremented whenever the icon source changes, to drop results of stale async work.
  NSUInteger _iconGeneration;
  __weak UIView* _customView;
}

+ (bool)shouldBeRecycled {
  return NO;
}

- (std::shared_ptr<RNCNaverMapMarkerEventEmitter const>)emitter {
  if (!_eventEmitter)
    return nullptr;
  return std::static_pointer_cast<RNCNaverMapMarkerEventEmitter const>(_eventEmitter);
}

- (instancetype)init {
  if ((self = [super init])) {
    _inner = [NMFMarker new];
    _isImageSetFromSubview = NO;
    _isIconReady = NO;
    _alpha = 1;
    _iconGeneration = 0;

    _inner.touchHandler = [self](NMFOverlay* overlay) -> BOOL {
      if (self.emitter) {
        self.emitter->onTapOverlay({});
        return YES;
      }
      return NO;
    };
  }

  return self;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    static const auto defaultProps = std::make_shared<const RNCNaverMapMarkerProps>();
    _props = defaultProps;
  }

  return self;
}

- (void)dealloc {
  [RNCNaverMapUtil closeInfoWindowsForMarker:_inner];

  if (_imageCanceller) {
    _imageCanceller();
    _imageCanceller = nil;
  }
}

/**
 * Ensures that the touch handler is properly set up for the marker
 * This method checks if the touch handler exists and creates it if it doesn't
 * The touch handler is responsible for processing tap events on the marker
 */
- (void)ensureTouchHandler {
  if (!_inner.touchHandler) {
    _inner.touchHandler = [self](NMFOverlay* overlay) -> BOOL {
      if (self.emitter) {
        self.emitter->onTapOverlay({});
        return YES;
      }
      return NO;
    };
  }
}

/**
 * Applies the alpha to the marker.
 * The marker stays transparent until its first icon is ready, and the previous icon stays
 * visible while a new one is being prepared. This prevents the default icon from flashing.
 */
- (void)applyAlpha {
  _inner.alpha = _isIconReady ? _alpha : 0;
}

- (void)setImage:(facebook::react::RNCNaverMapMarkerImageStruct)image {
  _image = image;
  // If subview exists for custom marker, then skip image
  if (_isImageSetFromSubview) {
    return;
  }
  [self applyAlpha];

  // Cancel pending request
  if (_imageCanceller) {
    _imageCanceller();
    _imageCanceller = nil;
  }

  NSUInteger generation = ++_iconGeneration;
  __weak RNCNaverMapMarker* weakSelf = self;
  _imageCanceller = nmap::getImage(image, ^(NMFOverlayImage* _Nullable image) {
    runOnMain([weakSelf, image, generation]() {
      RNCNaverMapMarker* strongSelf = weakSelf;
      // The image prop was changed again or a custom view was mounted in the meantime
      if (!strongSelf || strongSelf->_iconGeneration != generation) {
        return;
      }
      if (image) {
        strongSelf.inner.iconImage = image;
      }
      strongSelf->_isIconReady = YES;
      [strongSelf applyAlpha];
      strongSelf->_imageCanceller = nil;
      [strongSelf ensureTouchHandler]; // Re-ensure touch handler after image is set
    });
  });
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-missing-super-calls"
- (void)mountChildComponentView:(UIView<RCTComponentViewProtocol>*)childComponentView
                          index:(NSInteger)index {
  [self insertReactSubview:childComponentView atIndex:index];
}
- (void)unmountChildComponentView:(UIView<RCTComponentViewProtocol>*)childComponentView
                            index:(NSInteger)index {
  [self removeReactSubview:childComponentView];
}

- (void)insertReactSubview:(UIView*)subview atIndex:(NSInteger)atIndex {
  if (_imageCanceller) {
    _imageCanceller();
    _imageCanceller = nil;
  }
  _isImageSetFromSubview = YES;
  _customView = subview;
  // Keep the current icon (if any) until the new custom view is captured.
  [self applyAlpha];

  NSUInteger generation = ++_iconGeneration;
  __weak RNCNaverMapMarker* weakSelf = self;
  // Capture after the current mounting transaction so that the subview is fully laid out.
  runOnMain([weakSelf, subview, generation]() {
    RNCNaverMapMarker* strongSelf = weakSelf;
    if (!strongSelf || strongSelf->_iconGeneration != generation) {
      return;
    }
    UIImage* captured = [strongSelf captureView:subview];
    if (captured) {
      strongSelf.inner.iconImage = [NMFOverlayImage overlayImageWithImage:captured];
      strongSelf->_isIconReady = YES;
    }
    [strongSelf applyAlpha];
    [strongSelf ensureTouchHandler]; // Re-ensure touch handler after custom marker image is set
  });
}

- (void)removeReactSubview:(UIView*)subview {
  if (_customView == subview) {
    _customView = nil;
  }

  // When the custom view is replaced (e.g. its `key` is changed), the removal is followed by an
  // insertion in the same mounting transaction. Falling back to the image prop right away would
  // show the default icon for a moment, so decide after the transaction is finished.
  __weak RNCNaverMapMarker* weakSelf = self;
  runOnMain([weakSelf]() {
    RNCNaverMapMarker* strongSelf = weakSelf;
    if (!strongSelf || strongSelf->_customView) {
      return;
    }
    strongSelf->_isImageSetFromSubview = NO;
    // after custom marker is removed, set image from prop.
    strongSelf.image = strongSelf->_image;
  });
}

- (UIImage*)captureView:(UIView*)view {
  if (CGRectIsEmpty(view.bounds)) {
    return nil;
  }
  UIGraphicsImageRenderer* renderer =
      [[UIGraphicsImageRenderer alloc] initWithSize:view.bounds.size];
  auto ret =
      [renderer imageWithActions:^(UIGraphicsImageRendererContext* _Nonnull rendererContext) {
        [view.layer renderInContext:rendererContext.CGContext];
      }];
  return ret;
}

#pragma clang diagnostic pop

- (void)updateProps:(Props::Shared const&)props oldProps:(Props::Shared const&)oldProps {
  const auto& prev = *std::static_pointer_cast<RNCNaverMapMarkerProps const>(_props);
  const auto& next = *std::static_pointer_cast<RNCNaverMapMarkerProps const>(props);

  if (!nmap::isCoordEqual(prev.coord, next.coord))
    _inner.position = nmap::createLatLng(next.coord);

  if (prev.zIndexValue != next.zIndexValue)
    _inner.zIndex = next.zIndexValue;
  if (prev.globalZIndexValue != next.globalZIndexValue && isValidNumber(next.globalZIndexValue))
    _inner.globalZIndex = next.globalZIndexValue;
  if (prev.isHidden != next.isHidden)
    _inner.hidden = next.isHidden;
  if (prev.minZoom != next.minZoom)
    _inner.minZoom = next.minZoom;
  if (prev.maxZoom != next.maxZoom)
    _inner.maxZoom = next.maxZoom;
  if (prev.isMinZoomInclusive != next.isMinZoomInclusive)
    _inner.isMinZoomInclusive = next.isMinZoomInclusive;
  if (prev.isMaxZoomInclusive != next.isMaxZoomInclusive)
    _inner.isMaxZoomInclusive = next.isMaxZoomInclusive;

  if (prev.width != next.width && isValidNumber(next.width))
    _inner.width = next.width;
  if (prev.height != next.height && isValidNumber(next.height))
    _inner.height = next.height;

  if (!nmap::isAnchorEqual(prev.anchor, next.anchor))
    _inner.anchor = nmap::createAnchorCGPoint(next.anchor);

  if (prev.angle != next.angle)
    _inner.angle = next.angle;
  if (prev.isFlatEnabled != next.isFlatEnabled)
    [_inner setFlat:next.isFlatEnabled];
  if (prev.isIconPerspectiveEnabled != next.isIconPerspectiveEnabled)
    [_inner setIconPerspectiveEnabled:next.isIconPerspectiveEnabled];
  if (prev.alpha != next.alpha) {
    _alpha = next.alpha;
    [self applyAlpha];
  }
  if (prev.isHideCollidedSymbols != next.isHideCollidedSymbols)
    [_inner setIsHideCollidedSymbols:next.isHideCollidedSymbols];
  if (prev.isHideCollidedMarkers != next.isHideCollidedMarkers)
    [_inner setIsHideCollidedMarkers:next.isHideCollidedMarkers];
  if (prev.isHideCollidedCaptions != next.isHideCollidedCaptions)
    [_inner setIsHideCollidedCaptions:next.isHideCollidedCaptions];
  if (prev.isForceShowIcon != next.isForceShowIcon)
    [_inner setIsForceShowIcon:next.isForceShowIcon];
  if (prev.tintColor != next.tintColor)
    [_inner setIconTintColor:nmap::intToColor(next.tintColor)];

  if (!nmap::isImageEqual(prev.image, next.image))
    self.image = next.image;

  if (next.caption.key != prev.caption.key) {
    auto caption = next.caption;
    _inner.captionText = getNsStr(caption.text);
    _inner.captionRequestedWidth = caption.requestedWidth;
    _inner.captionAligns = @[ nmap::createAlign(caption.align) ];
    _inner.captionOffset = caption.offset;
    _inner.captionColor = nmap::intToColor(caption.color);
    _inner.captionHaloColor = nmap::intToColor(caption.haloColor);
    _inner.captionTextSize = caption.textSize;
    _inner.captionMinZoom = caption.minZoom;
    _inner.captionMaxZoom = caption.maxZoom;
  }

  if (next.subCaption.key != prev.subCaption.key) {
    auto caption = next.subCaption;
    _inner.subCaptionText = getNsStr(caption.text);
    _inner.subCaptionRequestedWidth = caption.requestedWidth;
    _inner.subCaptionColor = nmap::intToColor(caption.color);
    _inner.subCaptionHaloColor = nmap::intToColor(caption.haloColor);
    _inner.subCaptionTextSize = caption.textSize;
    _inner.subCaptionMinZoom = caption.minZoom;
    _inner.subCaptionMaxZoom = caption.maxZoom;
  }

  [super updateProps:props oldProps:oldProps];

  // Ensure touch handler is properly set after marker properties are updated
  [self ensureTouchHandler];
}

Class<RCTComponentViewProtocol> RNCNaverMapMarkerCls(void) {
  return RNCNaverMapMarker.class;
}

+ (ComponentDescriptorProvider)componentDescriptorProvider {
  return concreteComponentDescriptorProvider<RNCNaverMapMarkerComponentDescriptor>();
}

- (void)handleCommand:(const NSString*)commandName args:(const NSArray*)args {
  RCTRNCNaverMapMarkerHandleCommand(self, commandName, args);
}

- (void)showInfoWindow:(NSString*)infoWindowId alignType:(NSInteger)alignType {
  NMFInfoWindow* infoWindow = [RNCNaverMapUtil getInfoWindow:infoWindowId];

  if (infoWindow) {
    if (isValidNumber((double)alignType)) {
      [infoWindow openWithMarker:_inner alignType:nmap::createAlign((int)alignType)];
    } else {
      [infoWindow openWithMarker:_inner];
    }
  }
}

@end
