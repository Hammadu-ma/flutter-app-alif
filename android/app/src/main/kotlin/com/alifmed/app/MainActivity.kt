package com.alifmed.app

import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import io.flutter.embedding.android.FlutterActivity
import java.util.Collections
import java.util.WeakHashMap

class MainActivity : FlutterActivity() {

    // Tracks WebViews already configured so repeated layout passes don't
    // redo the same work.
    private val configuredWebViews: MutableSet<WebView> =
        Collections.newSetFromMap(WeakHashMap())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The site's CSS follows the system theme via `prefers-color-scheme`.
        // For apps targeting Android 13 (API 33)+, WebView ignores that media
        // query unless "algorithmic darkening" is explicitly turned on per
        // WebView instance — there's no app-wide setting for it, and
        // webview_flutter doesn't expose it from Dart, so it's applied here
        // natively whenever a WebView shows up in the view tree.
        window.decorView.viewTreeObserver.addOnGlobalLayoutListener {
            enableSystemThemeSupport(window.decorView)
        }
    }

    private fun enableSystemThemeSupport(view: View) {
        if (view is WebView) {
            if (!configuredWebViews.contains(view) &&
                WebViewFeature.isFeatureSupported(WebViewFeature.ALGORITHMIC_DARKENING)
            ) {
                WebSettingsCompat.setAlgorithmicDarkeningAllowed(view.settings, true)
                configuredWebViews.add(view)
            }
        } else if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                enableSystemThemeSupport(view.getChildAt(i))
            }
        }
    }
}
