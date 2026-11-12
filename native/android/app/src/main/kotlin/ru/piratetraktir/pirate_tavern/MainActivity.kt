package ru.piratetraktir.pirate_tavern

import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        preferFastDisplay()
    }

    override fun onResume() {
        super.onResume()
        preferFastDisplay()
    }

    @Suppress("DEPRECATION")
    private fun preferFastDisplay() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val display = windowManager.defaultDisplay
        val current = display.mode
        val fastest = display.supportedModes
            .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
            .maxByOrNull { it.refreshRate } ?: return
        // Let Flutter's vsync follow the display at 90/120/144 Hz instead of
        // leaving a high-FPS decoded stream on the Android default 60 Hz mode.
        val params = window.attributes
        params.preferredDisplayModeId = fastest.modeId
        params.preferredRefreshRate = fastest.refreshRate
        window.attributes = params
    }
}
