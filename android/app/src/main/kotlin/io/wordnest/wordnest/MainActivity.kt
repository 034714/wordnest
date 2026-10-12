package io.wordnest.wordnest

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.provider.CalendarContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var studySounds: StudySoundPlayer? = null
    private var nativeSpeech: NativeSpeechPlayer? = null

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.wordnest/sound")
            .setMethodCallHandler(null)
        nativeSpeech?.release()
        nativeSpeech = null
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.wordnest/tts")
            .setMethodCallHandler(null)
        studySounds?.release()
        studySounds = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val updater = UpdaterBridge(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.wordnest/updater")
            .setMethodCallHandler(updater::handle)
        val speechChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.wordnest/tts")
        nativeSpeech = NativeSpeechPlayer(this, speechChannel)
        speechChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "playWordAudio" -> nativeSpeech?.playAudio(call.argument<String>("path"), result)
                "stopWordAudio" -> { nativeSpeech?.stopAudio(); result.success(null) }
                "openTtsSettings" -> nativeSpeech?.openSettings(false, call.argument<String>("engine"), result)
                "installVoiceData" -> nativeSpeech?.openSettings(true, call.argument<String>("engine"), result)
                "initialize" -> nativeSpeech?.initialize(call.argument<String>("engine"), result)
                "speak" -> nativeSpeech?.speak(call.argument<String>("text"), result)
                "stop" -> { nativeSpeech?.stop(); result.success(null) }
                else -> result.notImplemented()
            }
        }
        studySounds = StudySoundPlayer(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.wordnest/sound")
            .setMethodCallHandler { call, result ->
                if (call.method == "play") {
                    studySounds?.play(call.argument<String>("sound"), call.argument<String>("pack") ?: "classic", result)
                        ?: result.error("sound_unavailable", "Sound player unavailable", null)
                } else result.notImplemented()
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.wordnest/calendar")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrBlank() ||
                            !(url.startsWith("http://") || url.startsWith("https://"))
                        ) {
                            result.error("invalid_url", "Invalid URL", null)
                            return@setMethodCallHandler
                        }
                        try {
                            startActivity(
                                Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                            )
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("open_url_failed", error.message, null)
                        }
                    }
                    "insertEvent" -> {
                        val title = call.argument<String>("title")
                        val description = call.argument<String>("description") ?: ""
                        val start = call.argument<Number>("startMillis")?.toLong()
                        val end = call.argument<Number>("endMillis")?.toLong()
                        if (title.isNullOrBlank() || start == null || end == null || end <= start) {
                            result.error("invalid_event", "Invalid calendar title or time range", null)
                            return@setMethodCallHandler
                        }
                        val intent = Intent(Intent.ACTION_INSERT).apply {
                            data = CalendarContract.Events.CONTENT_URI
                            putExtra(CalendarContract.Events.TITLE, title)
                            putExtra(CalendarContract.Events.DESCRIPTION, description)
                            putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, start)
                            putExtra(CalendarContract.EXTRA_EVENT_END_TIME, end)
                        }
                        try {
                            // The calendar app owns confirmation. No read/write calendar
                            // permissions or provider access are needed by WordNest.
                            startActivity(intent)
                            result.success(null)
                        } catch (_: ActivityNotFoundException) {
                            result.error("calendar_unavailable", "No calendar editor installed", null)
                        } catch (error: Exception) {
                            result.error("calendar_failed", error.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
