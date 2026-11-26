
package com.example.arcaea_chart_editor

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import java.io.ByteArrayOutputStream
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val pickerCode = 17542
    private val storageExecutor = Executors.newSingleThreadExecutor()
    private val artworkExecutor = Executors.newFixedThreadPool(3)
    private val artworkIndex = LruCache<Uri, Map<String, Entry>>(768)
    private data class ArtworkKey(val uri: Uri, val maxWidth: Int)
    private val thumbnails = object : LruCache<ArtworkKey, ByteArray>(24 * 1024 * 1024) {
        override fun sizeOf(key: ArtworkKey, value: ByteArray): Int = value.size
    }
    @Volatile private var artworkRevision = 0
    private data class DirectoryPicker(val result: MethodChannel.Result, val persist: Boolean)
    private var pendingPicker: DirectoryPicker? = null
    private var chartAudio: ChartAudio? = null
    private var calibrationAudio: ChartAudio? = null
    private var displayPerformance: DisplayPerformance? = null
    private var savedSystemUi: Int? = null
    private var savedBarBehavior: Int? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        displayPerformance = DisplayPerformance(this, flutterEngine.dartExecutor.binaryMessenger)
        window.decorView.post { displayPerformance?.apply() }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "arcaea_manager/chart_window")
            .setMethodCallHandler { call, result ->
                if (call.method == "immersive") {
                    setChartImmersive(call.arguments == true)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        chartAudio = ChartAudio(
            this,
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "arcaea_manager/chart_audio")
        ) { tree, path ->
            val entry = find(Uri.parse(tree), segments(path))
            if (entry == null || entry.isDirectory) throw IOException("找不到谱面音频")
            entry.uri
        }
        calibrationAudio = ChartAudio(
            this,
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "arcaea_manager/chart_calibration_audio")
        ) { _, _ -> throw IOException("校准鼓点必须使用本地文件") }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "arcaea_manager/treestorage")
            .setMethodCallHandler { call, result ->
                if (call.method == "pick") {
                    pickDirectory(
                        result,
                        call.argument<Boolean>("persist") ?: true,
                        call.argument<Boolean>("write") ?: false
                    )
                } else if (call.method == "invalidateArtwork") {
                    synchronized(artworkIndex) {
                        artworkRevision++
                        artworkIndex.evictAll()
                        thumbnails.evictAll()
                    }
                    result.success(null)
                } else {
                    val isArtwork = call.method == "firstImage"
                    val executor = if (isArtwork) artworkExecutor else storageExecutor
                    executor.execute {
                        try {
                            val value = if (isArtwork) firstArtwork(call) else handleStorage(call)
                            runOnUiThread { result.success(value) }
                        } catch (error: Exception) {
                            runOnUiThread { result.error("storage", error.message, null) }
                        }
                    }
                }
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        displayPerformance?.close()
        displayPerformance = null
        setChartImmersive(false)
        calibrationAudio?.dispose()
        calibrationAudio = null
        chartAudio?.dispose()
        chartAudio = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onResume() {
        super.onResume()
        window.decorView.post { displayPerformance?.apply() }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) displayPerformance?.apply()
    }

    @Suppress("DEPRECATION")
    private fun setChartImmersive(enabled: Boolean) {
        if (Build.VERSION.SDK_INT >= 30) {
            val controller = window.insetsController ?: return
            val bars = WindowInsets.Type.systemBars()
            if (enabled) {
                if (savedBarBehavior == null) savedBarBehavior = controller.systemBarsBehavior
                controller.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                controller.hide(bars)
            } else if (savedBarBehavior != null) {
                controller.show(bars)
                controller.systemBarsBehavior = savedBarBehavior!!
                savedBarBehavior = null
            }
        } else {
            val decor = window.decorView
            if (enabled) {
                if (savedSystemUi == null) savedSystemUi = decor.systemUiVisibility
                decor.systemUiVisibility = decor.systemUiVisibility or
                    View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            } else if (savedSystemUi != null) {
                decor.systemUiVisibility = savedSystemUi!!
                savedSystemUi = null
            }
        }
    }

    private fun pickDirectory(result: MethodChannel.Result, persist: Boolean, write: Boolean) {
        if (pendingPicker != null) {
            result.error("picker_busy", "目录选择器已打开", null)
            return
        }
        pendingPicker = DirectoryPicker(result, persist)
        try {
            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                if (write) addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                if (persist) {
                    addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                }
            }, pickerCode)
        } catch (error: Exception) {
            pendingPicker = null
            result.error("picker", error.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickerCode) return
        val picker = pendingPicker ?: return
        val result = picker.result
        pendingPicker = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        try {
            if (picker.persist) {
                val access = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                val granted = data.flags and access
                check(granted == access) { "所选目录未授权读写" }
                contentResolver.takePersistableUriPermission(uri, granted)
            }
            result.success(uri.toString())
        } catch (error: Exception) {
            result.error("directory_permission", error.message, null)
        }
    }

    private data class Entry(val uri: Uri, val name: String, val mime: String) {
        val isDirectory get() = mime == Document.MIME_TYPE_DIR
        val kind get() = if (isDirectory) "directory" else "file"
    }

    private fun entries(tree: Uri, directory: Uri): List<Entry> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(
            tree, DocumentsContract.getDocumentId(directory)
        )
        val columns = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE)
        val cursor = contentResolver.query(uri, columns, null, null, null)
            ?: throw IOException("无法列出目录")
        return cursor.use {
            buildList {
                while (it.moveToNext()) {
                    add(Entry(DocumentsContract.buildDocumentUriUsingTree(tree, it.getString(0)),
                        it.getString(1), it.getString(2)))
                }
            }
        }
    }

    private fun segments(path: String): List<String> = if (path.isEmpty()) emptyList() else {
        path.split('/').also { parts ->
            require(parts.none { it.isEmpty() || it == "." || it == ".." || '\\' in it })
        }
    }

    private fun find(
        tree: Uri, path: List<String>,
        cache: MutableMap<Uri, List<Entry>> = mutableMapOf()
    ): Entry? {
        var current = Entry(
            DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree)),
            "", Document.MIME_TYPE_DIR
        )
        for (name in path) {
            if (!current.isDirectory) return null
            val directory = current.uri
            val matches = cache.getOrPut(directory) { entries(tree, directory) }
                .filter { it.name == name }
            check(matches.size <= 1) { "目录内有多个同名条目 $name" }
            current = matches.firstOrNull() ?: return null
        }
        return current
    }

    private fun create(tree: Uri, path: List<String>, mime: String): Uri {
        val parent = find(tree, path.dropLast(1)) ?: throw IOException("父目录不存在")
        val name = path.last()
        val created = DocumentsContract.createDocument(contentResolver, parent.uri, mime, name)
            ?: throw IOException("无法创建 $name")
        try {
            if (displayName(created) == name) return created
            val renamed = DocumentsContract.renameDocument(contentResolver, created, name)
                ?: throw IOException("文件提供程序无法使用指定名称 $name")
            if (displayName(renamed) == name) return renamed
            DocumentsContract.deleteDocument(contentResolver, renamed)
            throw IOException("文件提供程序修改了名称 $name")
        } catch (error: Exception) {
            runCatching { DocumentsContract.deleteDocument(contentResolver, created) }
            throw error
        }
    }

    private fun displayName(uri: Uri): String? =
        contentResolver.query(uri, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null }

    private fun firstArtwork(call: MethodCall): ByteArray? {
        val tree = Uri.parse(call.argument<String>("tree")!!)
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val revision = artworkRevision
        val maxWidth = (call.argument<Int>("width") ?: 640).coerceIn(48, 1600)

        for (candidate in call.argument<List<String>>("candidates")!!) {
            var current = Entry(root, "", Document.MIME_TYPE_DIR)
            var found = true
            for (name in segments(candidate)) {
                if (!current.isDirectory) {
                    found = false
                    break
                }
                val directory = current.uri
                val children = artworkIndex.get(directory) ?: entries(tree, directory)
                    .associateBy { it.name }.also {
                        synchronized(artworkIndex) {
                            if (artworkRevision == revision) artworkIndex.put(directory, it)
                        }
                    }
                val child = children[name]
                if (child == null) {
                    found = false
                    break
                }
                current = child
            }
            if (!found || current.isDirectory) continue
            val key = ArtworkKey(current.uri, maxWidth)
            val cached = thumbnails.get(key)
            if (cached != null) return cached
            val bytes = try {
                thumbnail(current.uri, maxWidth)
            } catch (_: java.io.FileNotFoundException) {
                null
            }
            if (bytes != null) {
                synchronized(artworkIndex) {
                    if (artworkRevision == revision) thumbnails.put(key, bytes)
                }
                return bytes
            }
        }
        return null
    }

    private fun thumbnail(uri: Uri, maxWidth: Int): ByteArray? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        val header = contentResolver.openInputStream(uri) ?: return null
        header.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val maxDimension = maxOf(bounds.outWidth, bounds.outHeight)
        if (maxDimension <= maxWidth) {
            return contentResolver.openInputStream(uri)?.use { it.readBytes() }
        }
        var sample = 1
        while (maxDimension / (sample * 2) >= maxWidth) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val decoded = contentResolver.openInputStream(uri)
            ?.use { BitmapFactory.decodeStream(it, null, options) } ?: return null
        val decodedDimension = maxOf(decoded.width, decoded.height)
        val scaled = if (decodedDimension > maxWidth) {
            val width = (decoded.width.toLong() * maxWidth / decodedDimension).toInt().coerceAtLeast(1)
            val height = (decoded.height.toLong() * maxWidth / decodedDimension).toInt().coerceAtLeast(1)
            Bitmap.createScaledBitmap(decoded, width, height, true)
        } else decoded
        try {
            val format = if (scaled.hasAlpha()) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG
            return ByteArrayOutputStream().use { output ->
                if (scaled.compress(format, 86, output)) output.toByteArray() else null
            }
        } finally {
            if (scaled !== decoded) scaled.recycle()
            decoded.recycle()
        }
    }

    private fun handleStorage(call: MethodCall): Any? {
        val tree = Uri.parse(call.argument<String>("tree")!!)
        if (call.method == "selectedFolderName") {
            return displayName(DocumentsContract.buildDocumentUriUsingTree(
                tree, DocumentsContract.getTreeDocumentId(tree)
            ))
        }
        if (call.method == "releasePermission") {
            val grant = contentResolver.persistedUriPermissions.firstOrNull { it.uri == tree }
            if (grant != null) {
                var flags = 0
                if (grant.isReadPermission) flags = flags or Intent.FLAG_GRANT_READ_URI_PERMISSION
                if (grant.isWritePermission) flags = flags or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                if (flags != 0) contentResolver.releasePersistableUriPermission(tree, flags)
            }
            return null
        }
        val path = segments(call.argument<String>("path")!!)
        val cache = mutableMapOf<Uri, List<Entry>>()
        val entry = find(tree, path, cache)
        val label = path.joinToString("/")
        return when (call.method) {
            "directoryId" -> entry?.takeIf { it.isDirectory }
                ?.let { DocumentsContract.getDocumentId(it.uri) }
            "kind" -> entry?.kind
            "list" -> entries(tree, requireNotNull(entry) { "找不到目录 $label" }.uri)
                .map { listOf(it.name, it.kind) }
            "songFiles" -> {
                val dirs = entries(tree, requireNotNull(entry).uri).filter { it.isDirectory }
                    .associateBy { it.name }
                call.argument<List<String>>("ids")!!.associateWith { id ->
                    dirs[id]?.let { dir ->
                        entries(tree, dir.uri).filterNot { it.isDirectory }.map { it.name }
                    } ?: emptyList()
                }
            }
            "read" -> contentResolver.openInputStream(requireNotNull(entry) { "找不到文件 $label" }.uri)
                ?.use { it.readBytes() } ?: throw IOException("无法读取 $label")
            "readFiles" -> {
                val names = call.argument<List<String>>("names")!!.toSet()
                require(names.all { segments(it).size == 1 })
                val files = entries(tree, requireNotNull(entry) { "找不到目录 $label" }.uri)
                    .filter { it.name in names }.groupBy { it.name }
                names.associateWith { name ->
                    val file = files[name]?.singleOrNull()?.takeUnless { it.isDirectory }
                        ?: throw IOException("找不到唯一的文件 $name")
                    contentResolver.openInputStream(file.uri)?.use { it.readBytes() }
                        ?: throw IOException("无法读取 $name")
                }
            }
            "write" -> {
                val uri = entry?.uri ?: create(tree, path, "application/octet-stream")
                val stream = contentResolver.openOutputStream(uri, "wt")
                    ?: throw IOException("无法写入 $label")
                stream.use {
                    it.write(call.argument<ByteArray>("bytes")!!)
                    it.flush()
                }
                null
            }
            "copy" -> {
                val source = requireNotNull(entry).uri
                val targetTree = Uri.parse(call.argument<String>("targetTree")!!)
                val target = segments(call.argument<String>("target")!!)
                check(find(targetTree, target) == null) { "复制目标已存在" }
                val targetUri = create(targetTree, target, "application/octet-stream")
                val input = contentResolver.openInputStream(source) ?: throw IOException("无法读取 $label")
                input.use { from ->
                    val output = contentResolver.openOutputStream(targetUri, "wt")
                        ?: throw IOException("无法写入目标文件")
                    output.use { to -> from.copyTo(to) }
                }
                null
            }
            "createDirectory" -> {
                if (entry != null) throw IOException("目录已存在 $label")
                create(tree, path, Document.MIME_TYPE_DIR)
                null
            }
            "rename" -> {
                val target = segments(call.argument<String>("target")!!)
                require(path.isNotEmpty() && target.isNotEmpty() && path.dropLast(1) == target.dropLast(1))
                check(find(tree, target) == null) { "目标已存在" }
                val renamed = DocumentsContract.renameDocument(contentResolver,
                    requireNotNull(entry) { "找不到 $label" }.uri, target.last())
                    ?: throw IOException("无法重命名 $label")
                if (displayName(renamed) != target.last()) {
                    DocumentsContract.renameDocument(contentResolver, renamed, path.last())
                    throw IOException("文件提供程序无法使用指定名称")
                }
                null
            }
            "removeEmptyDirectory" -> {
                require(entry != null && entry.isDirectory)
                check(entries(tree, entry.uri).isEmpty()) { "目录非空 $label" }
                check(DocumentsContract.deleteDocument(contentResolver, entry.uri)) { "无法删除 $label" }
                null
            }
            "removeFile" -> {
                require(entry != null && !entry.isDirectory) { "找不到文件 $label" }
                check(DocumentsContract.deleteDocument(contentResolver, entry.uri)) { "无法删除 $label" }
                null
            }
            else -> throw IllegalArgumentException("未知的存储操作")
        }
    }

    override fun onDestroy() {
        storageExecutor.shutdown()
        artworkExecutor.shutdown()
        super.onDestroy()
    }
}
