package com.example.arcaea_chart_editor

import android.app.Activity
import android.app.GameManager
import android.os.Build
import android.view.Display
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

internal class DisplayPerformance(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "arcaea_manager/display_performance")
    private val prefs = activity.getSharedPreferences("display_performance", Activity.MODE_PRIVATE)
    private var requestedRate = prefs.getInt("rate", 0)
    private var followGameMode = prefs.getBoolean("game_mode", true)
    private var surface: SurfaceHolder? = null
    private var votedRate = 0f
    private var closed = false
    private val surfaceCallback = object : SurfaceHolder.Callback {
        override fun surfaceCreated(holder: SurfaceHolder) = voteSurface(holder)
        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) =
            voteSurface(holder)
        override fun surfaceDestroyed(holder: SurfaceHolder) = Unit
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> {
                    apply()
                    result.success(status())
                }
                "configure" -> {
                    requestedRate = call.argument<Int>("rate")?.coerceIn(-1, 1000) ?: 0
                    followGameMode = call.argument<Boolean>("followGameMode") ?: true
                    prefs.edit().putInt("rate", requestedRate)
                        .putBoolean("game_mode", followGameMode).apply()
                    apply()
                    result.success(status())
                }
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun currentDisplay(): Display =
        activity.window.decorView.display ?: activity.windowManager.defaultDisplay

    private fun gameMode(): Int {
        if (Build.VERSION.SDK_INT < 31) return 0
        return try {
            activity.getSystemService(GameManager::class.java)?.gameMode ?: 0
        } catch (_: SecurityException) {
            0
        }
    }

    private fun modes(display: Display): List<Display.Mode> {
        val current = display.mode
        return display.supportedModes.filter {
            it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight
        }
    }

    private fun status(): Map<String, Any> {
        val display = currentDisplay()
        return mapOf(
            "rate" to requestedRate,
            "rates" to modes(display).map { kotlin.math.round(it.refreshRate).toInt() }.distinct().sorted(),
            "currentRate" to display.refreshRate.toDouble(),
            "effectiveRequest" to votedRate.toDouble(),
            "gameMode" to gameMode(),
            "followGameMode" to followGameMode,
        )
    }

    fun apply() {
        if (closed) return
        val display = currentDisplay()
        val modes = modes(display)
        val target = when {
            requestedRate != 0 -> requestedRate
            !followGameMode -> 0
            gameMode() == 2 -> -1
            gameMode() == 3 -> 60
            else -> 0
        }
        val mode = when (target) {
            0 -> null
            -1 -> modes.maxByOrNull { it.refreshRate }
            else -> modes.minByOrNull { kotlin.math.abs(it.refreshRate - target) }
        }
        votedRate = mode?.refreshRate ?: 0f
        val window = activity.window
        val attributes = window.attributes
        val modeId = mode?.modeId ?: 0
        if (attributes.preferredDisplayModeId != modeId) {
            attributes.preferredDisplayModeId = modeId
            window.attributes = attributes
        }
        bindSurface()
    }

    private fun bindSurface() {
        val holder = findSurface(activity.window.decorView)?.holder
        if (surface != holder) {
            surface?.removeCallback(surfaceCallback)
            surface = holder
            holder?.addCallback(surfaceCallback)
        }
        holder?.let(::voteSurface)
    }

    private fun findSurface(view: View): SurfaceView? {
        if (view is SurfaceView) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                findSurface(view.getChildAt(i))?.let { return it }
            }
        }
        return null
    }

    private fun voteSurface(holder: SurfaceHolder) {
        if (Build.VERSION.SDK_INT < 30 || !holder.surface.isValid) return
        try {
            holder.surface.setFrameRate(votedRate, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
        } catch (_: IllegalStateException) {
            // The surface can be released between the validity check and the vote.
        } catch (_: IllegalArgumentException) {
            // The compositor may reject a vote while switching display modes.
        }
    }

    fun close() {
        closed = true
        surface?.removeCallback(surfaceCallback)
        surface = null
        channel.setMethodCallHandler(null)
    }
}
