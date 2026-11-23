package dev.pyvis.pyvis_editor

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.StandardMethodCodec
import io.flutter.plugin.common.MethodChannel
import java.io.File
import android.system.Os
import android.os.Build
import java.util.zip.ZipInputStream

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "dev.pyvis/workspace", StandardMethodCodec.INSTANCE, messenger.makeBackgroundTaskQueue())
            .setMethodCallHandler { call, result ->
                if (call.method != "prepareExamples") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val workspace = File(filesDir, "learning-workspace")
                try {
                    copyExamples("examples", File(workspace, "examples"))
                    val native = File(applicationInfo.nativeLibraryDir)
                    val abi = if (native.name == "arm64") "arm64-v8a" else Build.SUPPORTED_ABIS.first { it == "arm64-v8a" || it == "x86_64" }
                    val updated = packageManager.getPackageInfo(packageName, 0).lastUpdateTime
                    val home = File(filesDir, "cpython-$updated")
                    if (!home.isDirectory) installPython(home, native, abi)
                    result.success(mapOf("root" to workspace.absolutePath, "home" to home.absolutePath,
                        "native" to native.absolutePath))
                } catch (error: Exception) {
                    result.error("workspace", error.message, null)
                }
            }
    }

    private fun installPython(home: File, native: File, abi: String) {
        val stage = File(filesDir, "python-stage-" + java.util.UUID.randomUUID())
        try {
            val extensions = File(stage, "lib/python3.14/lib-dynload")
            extensions.mkdirs()
            native.listFiles().orEmpty().filter { it.name.startsWith("libpyext_") }.forEach {
                Os.symlink(it.path, File(extensions, it.name.removePrefix("libpyext_")).path)
            }
            assets.open("cpython/stdlib.payload").use { input ->
                File(stage, "lib/python314.zip").outputStream().use { input.copyTo(it) }
            }
            unpackAsset("cpython/$abi.zip", extensions.parentFile!!)
            unpackAsset("cpython/runtime.zip", File(stage, "runtime"))
            check(stage.renameTo(home) || home.isDirectory)
            filesDir.listFiles().orEmpty().filter { it != home && it.name.matches(Regex("cpython-[0-9]+")) }
                .forEach { it.deleteRecursively() }
        } finally {
            if (stage.exists()) stage.deleteRecursively()
        }
    }

    private fun unpackAsset(asset: String, directory: File) {
        ZipInputStream(assets.open(asset)).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                val target = File(directory, entry.name)
                target.parentFile!!.mkdirs()
                target.outputStream().use { zip.copyTo(it) }
            }
        }
    }

    private fun copyExamples(path: String, directory: File) {
        directory.mkdirs()
        for (name in assets.list(path).orEmpty()) {
            val destination = File(directory, name)
            val source = "$path/$name"
            if (!name.endsWith(".py")) {
                copyExamples(source, destination)
            } else if (!destination.exists()) {
                val temp = File.createTempFile(".example-", ".tmp", directory)
                try {
                    assets.open(source).use { input ->
                        temp.outputStream().use { output -> input.copyTo(output) }
                    }
                    if (!temp.renameTo(destination)) throw java.io.IOException("无法保存示例 $name")
                } finally {
                    temp.delete()
                }
            }
        }
    }
}
