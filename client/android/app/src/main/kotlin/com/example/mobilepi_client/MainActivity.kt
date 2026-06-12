package com.example.mobilepi_client

import android.os.Build
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        preferHighestRefreshRate()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            preferHighestRefreshRate()
        }
    }

    private fun preferHighestRefreshRate() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            Log.i(refreshLogTag, "event=refresh_mode_skip reason=unsupported_sdk sdk=${Build.VERSION.SDK_INT}")
            return
        }

        val currentMode = windowManager.defaultDisplay.mode ?: return
        val bestMode = windowManager.defaultDisplay.supportedModes
            .filter {
                it.physicalWidth == currentMode.physicalWidth &&
                    it.physicalHeight == currentMode.physicalHeight
            }
            .maxByOrNull { it.refreshRate } ?: return

        if (bestMode.modeId == window.attributes.preferredDisplayModeId) {
            Log.i(
                refreshLogTag,
                "event=refresh_mode_already_selected modeId=${bestMode.modeId} " +
                    "refreshRate=${bestMode.refreshRate} width=${bestMode.physicalWidth} " +
                    "height=${bestMode.physicalHeight}"
            )
            return
        }

        window.attributes = window.attributes.apply {
            preferredDisplayModeId = bestMode.modeId
        }
        Log.i(
            refreshLogTag,
            "event=refresh_mode_selected currentModeId=${currentMode.modeId} " +
                "selectedModeId=${bestMode.modeId} currentRefreshRate=${currentMode.refreshRate} " +
                "selectedRefreshRate=${bestMode.refreshRate} width=${bestMode.physicalWidth} " +
                "height=${bestMode.physicalHeight}"
        )
    }

    companion object {
        private const val refreshLogTag = "MobilePiRefresh"
    }
}
