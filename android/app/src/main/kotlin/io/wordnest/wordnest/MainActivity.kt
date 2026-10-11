package io.wordnest.wordnest

import android.content.ActivityNotFoundException
import android.content.Intent
import android.provider.CalendarContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.wordnest/calendar")
            .setMethodCallHandler { call, result ->
                if (call.method != "insertEvent") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
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
    }
}
