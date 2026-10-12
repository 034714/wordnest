package io.wordnest.wordnest

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import java.io.File
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/** Independent recovery path; requires an installed engine and offline English voice. */
internal class NativeSpeechPlayer(private val context: Context, private val channel: MethodChannel) {
    private val handler = Handler(Looper.getMainLooper())
    private var tts: TextToSpeech? = null
    private var pending: MethodChannel.Result? = null
    private var generation = 0
    private var ready = false

    fun initialize(engine: String?, result: MethodChannel.Result) {
        release()
        val token = generation
        pending = result
        val listener = TextToSpeech.OnInitListener { status ->
            handler.post {
                if (token == generation && pending != null) {
                    val speech = tts
                    if (status != TextToSpeech.SUCCESS || speech == null) {
                        fail("系统引擎初始化失败，请选择其他引擎或安装语音数据")
                    } else {
                        val language = speech.setLanguage(Locale.US)
                        val voice = speech.voices?.firstOrNull {
                            it.locale.language == "en" && it.locale.country == "US" && !it.isNetworkConnectionRequired
                        } ?: speech.voices?.firstOrNull {
                            it.locale.language == "en" && !it.isNetworkConnectionRequired
                        }
                        if (language < TextToSpeech.LANG_AVAILABLE || voice == null) {
                            fail("需要系统英语离线语音数据；没有引擎时无法离线朗读")
                        } else {
                            speech.voice = voice
                            speech.setSpeechRate(0.9f)
                            speech.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                                override fun onStart(id: String?) {}
                                override fun onDone(id: String?) {}
                                @Deprecated("Android legacy callback")
                                override fun onError(id: String?) {
                                    handler.post {
                                        if (token == generation) channel.invokeMethod("error", "系统原生引擎播放失败，请检查英语语音数据和媒体音量")
                                    }
                                }
                            })
                            ready = true
                            pending?.success(null)
                            pending = null
                        }
                    }
                }
            }
        }
        tts = if (engine.isNullOrBlank()) TextToSpeech(context, listener)
            else TextToSpeech(context, listener, engine)
        handler.postDelayed({
            if (token == generation && pending != null) fail("系统引擎初始化超时，可重试或切换引擎")
        }, 8000)
    }

    private fun fail(message: String) {
        pending?.error("tts_unavailable", message, null)
        pending = null
        ready = false
        tts?.shutdown()
        tts = null
    }

    fun speak(text: String?, result: MethodChannel.Result) {
        if (!ready || text.isNullOrBlank() || text.length > TextToSpeech.getMaxSpeechInputLength()) {
            result.error("tts_unavailable", "原生朗读未就绪或文本无效", null)
            return
        }
        val params = Bundle().apply { putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, 1f) }
        val code = tts?.speak(text, TextToSpeech.QUEUE_FLUSH, params, "wordnest-${System.nanoTime()}")
        if (code == TextToSpeech.SUCCESS) result.success(null)
        else result.error("tts_rejected", "系统引擎拒绝朗读", code)
    }

    private var audio: MediaPlayer? = null
    private var audioResult: MethodChannel.Result? = null

    fun stopAudio() {
        audioResult?.success(null)
        audioResult = null
        audio?.release()
        audio = null
    }

    fun playAudio(path: String?, result: MethodChannel.Result) {
        stopAudio()
        try {
            val file = File(path ?: "").canonicalFile
            val root = File(context.filesDir, "word-audio-v1").canonicalFile
            if (file.parentFile != root || !file.isFile || file.extension != "mp3" ||
                file.length() !in 1..1048576) throw IllegalArgumentException("Invalid cached word audio")
            val player = MediaPlayer()
            audio = player
            audioResult = result
            player.setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            player.setOnPreparedListener {
                if (audio === it) {
                    it.start()
                    audioResult?.success(null)
                    audioResult = null
                }
            }
            player.setOnCompletionListener { if (audio === it) stopAudio() }
            player.setOnErrorListener { p, what, extra ->
                if (audio === p) {
                    if (audioResult != null) {
                        audioResult?.error("word_audio_failed", "MP3 decode/play failed ($what/$extra)", null)
                        audioResult = null
                    } else channel.invokeMethod("error", "词音频播放失败，请检查媒体音量或重试")
                    stopAudio()
                }
                true
            }
            player.setDataSource(file.path)
            player.prepareAsync()
            handler.postDelayed({
                if (audio === player && audioResult != null) {
                    audioResult?.error("word_audio_timeout", "MP3 preparation timed out", null)
                    audioResult = null
                    stopAudio()
                }
            }, 10000)
        } catch (error: Exception) {
            audioResult = null
            stopAudio()
            result.error("word_audio_failed", error.message, null)
        }
    }

    fun openSettings(installData: Boolean, engine: String?, result: MethodChannel.Result) {
        try {
            val intent = Intent(if (installData) TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA
                else "com.android.settings.TTS_SETTINGS")
            if (installData && !engine.isNullOrBlank()) intent.setPackage(engine)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            result.success(null)
        } catch (error: Exception) {
            result.error("tts_settings_unavailable", "系统没有对应设置/语音安装页，请手动进入系统设置安装英语语音：${error.message}", null)
        }
    }

    fun stop() { tts?.stop() }

    fun release() {
        stopAudio()
        generation++
        handler.removeCallbacksAndMessages(null)
        pending?.error("tts_closed", "朗读初始化已取消", null)
        pending = null
        ready = false
        tts?.stop()
        tts?.shutdown()
        tts = null
    }
}
