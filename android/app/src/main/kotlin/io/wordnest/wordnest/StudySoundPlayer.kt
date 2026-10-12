package io.wordnest.wordnest

import android.content.Context
import android.media.AudioAttributes
import android.media.SoundPool
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/** Offline PCM effects on the media stream, independent of system touch sounds. */
internal class StudySoundPlayer(context: Context) {
    private val handler = Handler(Looper.getMainLooper())
    private val pool = SoundPool.Builder().setMaxStreams(4).setAudioAttributes(
        AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_GAME)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
    ).build()
    private val sounds = mutableMapOf<String, Int>()
    private val loaded = mutableSetOf<Int>()
    private val failures = mutableSetOf<Int>()
    private val pending = mutableMapOf<Int, MutableList<MethodChannel.Result>>()
    private var released = false

    init {
        pool.setOnLoadCompleteListener { _, id, status ->
            handler.post {
                if (!released) {
                    if (status == 0) loaded.add(id) else failures.add(id)
                    pending.remove(id)?.forEach { result ->
                        if (status == 0) playLoaded(id, result)
                        else result.error("sound_load_failed", "Offline sound could not load", null)
                    }
                }
            }
        }
        mapOf("classic/key" to R.raw.study_key, "classic/correct" to R.raw.study_correct,
            "classic/incorrect" to R.raw.study_incorrect,
            "soft/key" to R.raw.study_soft_key, "soft/correct" to R.raw.study_soft_correct,
            "soft/incorrect" to R.raw.study_soft_incorrect,
            "digital/key" to R.raw.study_digital_key, "digital/correct" to R.raw.study_digital_correct,
            "digital/incorrect" to R.raw.study_digital_incorrect).forEach { (name, resource) ->
            sounds[name] = pool.load(context, resource, 1)
        }
    }

    fun play(name: String?, pack: String, result: MethodChannel.Result) {
        val id = sounds["$pack/$name"]
        if (released || id == null || id == 0 || failures.contains(id)) {
            result.error("sound_unavailable", "Offline sound unavailable", null)
        } else if (loaded.contains(id)) {
            playLoaded(id, result)
        } else {
            val queue = pending.getOrPut(id) { mutableListOf() }
            // Keep only the latest keystroke while decoding (no burst afterwards).
            queue.forEach { it.success(null) }
            queue.clear()
            queue.add(result)
            handler.postDelayed({
                if (pending[id]?.remove(result) == true) {
                    result.error("sound_timeout", "Offline sound load timed out", null)
                }
            }, 3000)
        }
    }

    private fun playLoaded(id: Int, result: MethodChannel.Result) {
        if (pool.play(id, 0.65f, 0.65f, 1, 0, 1f) == 0) {
            result.error("sound_play_failed", "SoundPool did not start a stream", null)
        } else result.success(null)
    }

    fun release() {
        released = true
        handler.removeCallbacksAndMessages(null)
        pending.values.flatten().forEach {
            it.error("sound_closed", "Sound player closed", null)
        }
        pending.clear()
        pool.release()
    }
}
