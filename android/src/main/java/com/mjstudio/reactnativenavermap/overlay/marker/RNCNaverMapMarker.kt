package com.mjstudio.reactnativenavermap.overlay.marker

import android.annotation.SuppressLint
import android.graphics.Canvas
import android.graphics.Color
import android.os.Build
import android.view.View
import androidx.annotation.RequiresApi
import androidx.core.graphics.createBitmap
import androidx.core.view.children
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.uimanager.ThemedReactContext
import com.mjstudio.reactnativenavermap.event.NaverMapOverlayTapEvent
import com.mjstudio.reactnativenavermap.util.emitEvent
import com.mjstudio.reactnativenavermap.util.getAlign
import com.mjstudio.reactnativenavermap.util.getDoubleOrNull
import com.mjstudio.reactnativenavermap.util.getIntOrNull
import com.mjstudio.reactnativenavermap.util.image.RNCNaverMapImageRenderableOverlay
import com.mjstudio.reactnativenavermap.util.px
import com.mjstudio.reactnativenavermap.util.view.TrackableView
import com.mjstudio.reactnativenavermap.util.view.ViewChangesTracker
import com.naver.maps.map.NaverMap
import com.naver.maps.map.overlay.Marker
import com.naver.maps.map.overlay.OverlayImage
import kotlin.math.max

@SuppressLint("ViewConstructor")
class RNCNaverMapMarker(
  val reactContext: ThemedReactContext,
) : RNCNaverMapImageRenderableOverlay<Marker>(reactContext),
  TrackableView {
  private var customView: View? = null

  private var isImageSetFromSubview = false

  // Whether the custom view should be drawn to the marker icon again on the next tracking tick.
  private var isCustomViewDirty = false
  private var lastRenderedWidth = 0
  private var lastRenderedHeight = 0

  private val customViewLayoutChangeListener =
    OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> isCustomViewDirty = true }

  private var lastCaptionKey = DEFAULT_CAPTION_KEY
  private var lastSubCaptionKey = DEFAULT_CAPTION_KEY

  override val overlay: Marker by lazy {
    Marker().apply {
      setOnClickListener {
        reactContext.emitEvent(id) { surfaceId, reactTag ->
          NaverMapOverlayTapEvent(
            surfaceId,
            reactTag,
          )
        }
        true
      }
    }
  }

  override fun addToMap(map: NaverMap) {
    overlay.map = map
  }

  override fun removeFromMap(map: NaverMap) {
    overlay.map = null
  }

  fun setCustomView(
    view: View,
    index: Int,
  ) {
    super.addView(view, index)
    isImageSetFromSubview = true
    if (view.layoutParams == null) {
      view.setLayoutParams(
        LayoutParams(
          LayoutParams.WRAP_CONTENT,
          LayoutParams.WRAP_CONTENT,
        ),
      )
    }
    view.addOnLayoutChangeListener(customViewLayoutChangeListener)
    if (!ViewChangesTracker.getInstance().containsMarker(this)) {
      ViewChangesTracker.getInstance().addMarker(this)
    }
    customView = view
    updateCustomView()
    overlay.alpha = 1f
  }

  fun removeCustomView(index: Int) {
    customView?.removeOnLayoutChangeListener(customViewLayoutChangeListener)
    customView = null
    super.removeView(children.elementAt(index))

    // When the custom view is replaced (e.g. its `key` is changed), the removal is followed by an
    // insertion in the same batch. Falling back to the image prop right away would show the
    // default icon for a moment, so decide after the batch is finished.
    // The bitmap of the icon is not recycled here because the map may still be drawing it.
    post {
      if (customView != null) return@post
      ViewChangesTracker.getInstance().removeMarker(this)
      isImageSetFromSubview = false
      setImageWithLastImage()
    }
  }

  override fun onDropViewInstance() {
    customView?.removeOnLayoutChangeListener(customViewLayoutChangeListener)
    customView = null
    ViewChangesTracker.getInstance().removeMarker(this)
    overlay.map = null
    overlay.onClickListener = null
    super.onDropViewInstance()
  }

  override fun requestLayout() {
    super.requestLayout()
    isCustomViewDirty = true
  }

  // Called when the custom view or one of its descendants needs to be drawn again.
  // (e.g. an image is loaded, a text is changed)
  @RequiresApi(Build.VERSION_CODES.O)
  override fun onDescendantInvalidated(
    child: View,
    target: View,
  ) {
    super.onDescendantInvalidated(child, target)
    isCustomViewDirty = true
  }

  private fun updateCustomView() {
    if (customView == null) return
    isCustomViewDirty = false
    lastRenderedWidth = overlay.width
    lastRenderedHeight = overlay.height

    // A new bitmap is created for every render instead of reusing the previous one, because
    // the previous one is owned by the map once it is passed as an icon.
    val bitmap = createBitmap(max(1, overlay.width), max(1, overlay.height))
    draw(Canvas(bitmap))
    setOverlayImage(OverlayImage.fromBitmap(bitmap))
  }

  override fun skipTryRender(): Boolean = isImageSetFromSubview

  override fun updateCustomForTracking(): Boolean = true

  override fun update() {
    // Drawing every custom view and uploading it as a new icon on every tick makes the app run
    // out of memory when there are many markers, so render only when something has changed.
    // `onDescendantInvalidated` is available from API 26, so always render below it.
    val isChanged =
      isCustomViewDirty ||
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
        lastRenderedWidth != overlay.width ||
        lastRenderedHeight != overlay.height
    if (isChanged) {
      updateCustomView()
    }
  }

  override fun setOverlayAlpha(alpha: Float) {
    overlay.alpha = alpha
  }

  override fun setOverlayImage(image: OverlayImage?) {
    overlay.icon =
      image ?: OverlayImage.fromBitmap(createBitmap(1, 1))
  }

  fun updateCaption(value: ReadableMap?) {
    value?.also { map ->
      val key = map.getString("key") ?: DEFAULT_CAPTION_KEY
      if (key == lastCaptionKey) return
      lastCaptionKey = key

      overlay.captionText = map.getString("text") ?: ""
      overlay.captionRequestedWidth = (map.getDoubleOrNull("requestedWidth") ?: 0.0).px
      overlay.setCaptionAligns(map.getAlign("align"))
      overlay.captionOffset = (map.getDoubleOrNull("offset") ?: 0.0).px
      overlay.captionColor = map.getIntOrNull("color") ?: Color.BLACK
      overlay.captionHaloColor = map.getIntOrNull("haloColor") ?: Color.TRANSPARENT
      overlay.captionTextSize = map.getDouble("textSize").toFloat()
      overlay.captionMinZoom = map.getDouble("minZoom")
      overlay.captionMaxZoom = map.getDouble("maxZoom")
    }
  }

  fun updateSubCaption(value: ReadableMap?) {
    value?.also { map ->
      val key = map.getString("key") ?: DEFAULT_CAPTION_KEY
      if (key == lastSubCaptionKey) return
      lastSubCaptionKey = key

      overlay.subCaptionText = map.getString("text") ?: ""
      overlay.subCaptionColor = map.getIntOrNull("color") ?: Color.BLACK
      overlay.subCaptionHaloColor = map.getIntOrNull("haloColor") ?: Color.TRANSPARENT
      overlay.subCaptionTextSize = map.getDouble("textSize").toFloat()
      overlay.subCaptionRequestedWidth = map.getDouble("requestedWidth").px
      overlay.subCaptionMinZoom = map.getDouble("minZoom")
      overlay.subCaptionMaxZoom = map.getDouble("maxZoom")
    }
  }

  companion object {
    const val DEFAULT_CAPTION_KEY = "DEFAULT"
  }
}
