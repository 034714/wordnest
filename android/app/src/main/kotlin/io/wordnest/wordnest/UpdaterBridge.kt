package io.wordnest.wordnest

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.Proxy
import java.net.ProxySelector
import java.net.URI
import java.net.InetSocketAddress

/** Only private updater-cache APKs can be handed to the system installer. */
class UpdaterBridge(private val activity: Activity) {
    private fun apk(path: String?): File {
        require(!path.isNullOrBlank()) { "Missing APK path" }
        val root = File(activity.cacheDir, "wordnest-updates").canonicalFile
        val file = File(path).canonicalFile
        require(file.path.startsWith(root.path + File.separator) &&
            file.isFile && file.extension == "apk" && file.length() in 1..536870912L) {
            "APK must be inside private updater cache"
        }
        return file
    }

    @Suppress("DEPRECATION")
    private fun validate(file: File) {
        val pm = activity.packageManager
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES
            else PackageManager.GET_SIGNATURES
        val candidate = pm.getPackageArchiveInfo(file.path, flags)
            ?: error("Invalid APK archive")
        val installed = pm.getPackageInfo(activity.packageName, flags)
        require(candidate.packageName == installed.packageName) { "APK package ID mismatch" }
        fun signatures(info: PackageInfo): Set<String> {
            val certs = if (Build.VERSION.SDK_INT >= 28)
                info.signingInfo?.apkContentsSigners else info.signatures
            return certs?.map { it.toCharsString() }?.toSet() ?: emptySet()
        }
        val old = signatures(installed)
        // Strict current signer equality, including multi-signer packages. Never
        // broaden to arbitrary lineage/private identities; OS verifies again.
        require(old.isNotEmpty() && signatures(candidate) == old) { "APK signature mismatch" }
        val newVersion = if (Build.VERSION.SDK_INT >= 28) candidate.longVersionCode
            else candidate.versionCode.toLong()
        val oldVersion = if (Build.VERSION.SDK_INT >= 28) installed.longVersionCode
            else installed.versionCode.toLong()
        require(newVersion > oldVersion) { "APK is not a newer installed version" }
    }

    fun handle(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "cacheDirectory" -> result.success(activity.cacheDir.absolutePath)
                "systemProxy" -> {
                    val uri = URI(call.argument<String>("url") ?: error("Missing URL"))
                    require(uri.scheme in listOf("http", "https"))
                    val proxy = ProxySelector.getDefault()?.select(uri)?.firstOrNull {
                        it.type() == Proxy.Type.HTTP && it.address() is InetSocketAddress
                    }
                    val endpoint = proxy?.address() as? InetSocketAddress
                    result.success(endpoint?.let { "${it.hostString}:${it.port}" })
                }
                "validateApk" -> { validate(apk(call.argument("path"))); result.success(null) }
                "installApk" -> {
                    val file = apk(call.argument("path"))
                    validate(file)
                    if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) {
                        activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:${activity.packageName}")))
                        result.success("permission")
                    } else {
                        val uri = FileProvider.getUriForFile(activity,
                            "${activity.packageName}.updater.files", file)
                        activity.startActivity(Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        })
                        result.success("confirmation")
                    }
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("updater_failed", error.message, null)
        }
    }
}
