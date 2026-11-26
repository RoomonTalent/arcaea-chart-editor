package com.example.arcaea_chart_editor

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class ChartAudio(
    private val context: Context,
    channel: MethodChannel,
    private val resolve: (String, String) -> Uri
) {
    private val thread = HandlerThread("ChartAudio").apply { start() }
    private val handler = Handler(thread.looper)
    private var player: MediaPlayer? = null
    private var preparing: MethodChannel.Result? = null
    private var seeking: MethodChannel.Result? = null
    private var failed = false
    private var gain = 1f

    init {
        channel.setMethodCallHandler { call, result ->
            if (!handler.post { handle(call, result) }) {
                result.error("audio_closed", "音频播放器已关闭", null)
            }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "open" -> open(call, result)
                "close" -> {
                    release()
                    result.success(null)
                }
                "volume" -> {
                    val value = requireNotNull(call.argument<Double>("gain"))
                    require(value.isFinite())
                    gain = value.coerceIn(0.0, 1.0).toFloat()
                    if (!failed && preparing == null) player?.setVolume(gain, gain)
                    result.success(null)
                }
                "play" -> {
                    ready().start()
                    result.success(null)
                }
                "pause" -> {
                    player?.takeIf { !failed && preparing == null && it.isPlaying }?.pause()
                    result.success(null)
                }
                "seek" -> {
                    val current = ready()
                    check(seeking == null) { "正在定位音频" }
                    val position = call.argument<Int>("position")!!.coerceIn(0, current.duration)
                    if (Build.VERSION.SDK_INT >= 26) {
                        current.seekTo(position.toLong(), MediaPlayer.SEEK_CLOSEST)
                    } else {
                        current.seekTo(position)
                    }
                    seeking = result
                }
                "position" -> {
                    val current = ready()
                    result.success(listOf(current.currentPosition, current.isPlaying))
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            if (call.method == "open") release()
            result.error("chart_audio", error.message ?: "音频操作失败", null)
        }
    }

    private fun ready(): MediaPlayer {
        check(!failed && preparing == null) { "音频尚未就绪" }
        return checkNotNull(player) { "还没有打开音频" }
    }

    private fun open(call: MethodCall, result: MethodChannel.Result) {
        release()
        failed = false
        val media = MediaPlayer()
        player = media
        val loop = call.argument<Boolean>("loop") == true
        media.setAudioAttributes(AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build())
        val tree = call.argument<String>("tree")
        if (tree == null) {
            media.setDataSource(call.argument<String>("file")!!)
        } else {
            media.setDataSource(context, resolve(tree, call.argument<String>("path")!!))
        }
        media.setOnPreparedListener {
            it.isLooping = loop
            it.setVolume(gain, gain)
            val pending = preparing
            preparing = null
            pending?.success(it.duration)
        }
        media.setOnSeekCompleteListener {
            val pending = seeking
            seeking = null
            pending?.success(it.currentPosition)
        }
        media.setOnErrorListener { _, what, extra ->
            failed = true
            val message = "无法播放所选音频 ($what/$extra)"
            preparing?.error("chart_audio", message, null)
            seeking?.error("chart_audio", message, null)
            preparing = null
            seeking = null
            true
        }
        media.prepareAsync()
        preparing = result
    }

    private fun release() {
        player?.release()
        player = null
        preparing?.error("audio_closed", "音频已关闭", null)
        seeking?.error("audio_closed", "音频已关闭", null)
        preparing = null
        seeking = null
    }

    fun dispose() {
        handler.post {
            release()
            thread.quitSafely()
        }
    }
}
