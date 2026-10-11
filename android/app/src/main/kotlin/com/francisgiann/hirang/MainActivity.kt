package com.francisgiann.hirang

import android.Manifest
import android.app.Activity
import android.content.ContentResolver
import android.content.ContentUris
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.Trace
import android.provider.MediaStore
import android.provider.Settings
import android.util.Size
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.min
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private val channelName = "app.hirang/media"
    private val trashRequestCode = 7104
    private val permissionRequestCode = 7105
    private val batchSize = 250
    private val maxOperationItems = 10_000
    private val preferencesName = "hirang_local_state"
    private val reviewStateKey = "review_state_v1"
    private val operationKey = "trash_operation_v1"
    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor: ExecutorService = Executors.newFixedThreadPool(2)
    private val imageExecutor: ExecutorService = ThreadPoolExecutor(
        2, 2, 0L, TimeUnit.MILLISECONDS, ArrayBlockingQueue(4), ThreadPoolExecutor.AbortPolicy(),
    )
    private val imageTraceCookie = AtomicInteger()
    private val photoTimingEnabled: Boolean
        get() = BuildConfig.DEBUG || BuildConfig.BUILD_TYPE == "profile"
    private var permissionResult: MethodChannel.Result? = null
    private val operationLock = Any()
    private val operationGate = TrashOperationGate()
    @Volatile private var activePromptOperationId: String? = null
    @Volatile private var activePromptToken: String? = null
    @Volatile private var activePromptRequestCode: Int? = null
    private var channel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val restoredId = savedInstanceState?.getString("hirang_prompt_operation")
        val restoredToken = savedInstanceState?.getString("hirang_prompt_token")
        val restoredRequestCode = savedInstanceState?.getInt("hirang_prompt_request_code")
        if (restoredId != null && restoredToken != null && restoredRequestCode != null) {
            activePromptOperationId = restoredId
            activePromptToken = restoredToken
            activePromptRequestCode = restoredRequestCode
            operationGate.restore(restoredId)
        } else {
            try {
                val journal = readOperation()
                if (journal?.get("status") == "awaitingSystemApproval") {
                    activePromptOperationId = journal["id"]?.toString()
                    activePromptToken = journal["batchToken"]?.toString()
                    activePromptRequestCode = (journal["requestCode"] as? Number)?.toInt()
                    activePromptOperationId?.let(operationGate::restore)
                }
            } catch (_: Exception) {
                // Keep an unreadable journal untouched; method-channel reads fail closed.
            }
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString("hirang_prompt_operation", activePromptOperationId)
        outState.putString("hirang_prompt_token", activePromptToken)
        activePromptRequestCode?.let { outState.putInt("hirang_prompt_request_code", it) }
        super.onSaveInstanceState(outState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler(::handleCall)
    }

    override fun onDestroy() {
        channel?.setMethodCallHandler(null)
        ioExecutor.shutdown()
        imageExecutor.shutdown()
        super.onDestroy()
    }

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "permissionStatus" -> result.success(permissionStatus())
            "requestPhotoAccess" -> requestPhotoAccess(result)
            "openAppSettings" -> openAppSettings(result)
            "loadReviewState" -> result.success(getPreferences().getString(reviewStateKey, null))
            "saveReviewState" -> saveReviewState(call, result)
            "queryPhotos" -> runIo(result) {
                if (!hasPhotoReadAccess()) emptyList<Map<String, Any?>>() else queryPhotos()
            }
            "loadThumbnail" -> {
                val args = call.argument<Map<String, Any?>>("asset")
                    ?: run {
                        result.error("invalid_photo", "Photo details are missing.", null)
                        return
                    }
                val requestedEdge = call.argument<Int>("width") ?: PhotoImagePolicy.PREVIEW_EDGE_PX
                val sourceDetail = call.argument<Boolean>("sourceDetail") == true
                runImageIo(result) { loadPhotoImage(args, requestedEdge, sourceDetail) }
            }
            "revalidate" -> runIo(result) {
                val items = call.argument<List<Map<String, Any?>>>("items") ?: emptyList()
                items.map { item -> mapOf("id" to item["id"], "status" to assetStatus(item)) }
            }
            "beginTrashOperation" -> beginTrashOperation(call, result)
            "continueTrashOperation" -> continueTrashOperation(call, result)
            "getTrashOperation" -> try {
                result.success(readOperation())
            } catch (_: Exception) {
                result.error("journal_unreadable", "The saved system-trash status could not be read.", null)
            }
            "reconcileTrashOperation" -> {
                val operationId = call.argument<String>("operationId")?.trim().orEmpty()
                val afterSystemScreenClosed = call.argument<Boolean>("afterSystemScreenClosed") == true
                if (afterSystemScreenClosed) acknowledgeSystemScreenClosed(operationId)
                runIo(result) { reconcileOperation(operationId, afterSystemScreenClosed) }
            }
            "clearTrashOperation" -> clearTrashOperation(call, result)
            else -> result.notImplemented()
        }
    }

    private fun requestPhotoAccess(result: MethodChannel.Result) {
        if (permissionResult != null) {
            result.error("permission_busy", "A photo permission request is already open.", null)
            return
        }
        val permissions = when {
            Build.VERSION.SDK_INT <= 32 -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
            Build.VERSION.SDK_INT >= 34 -> arrayOf(
                Manifest.permission.READ_MEDIA_IMAGES,
                Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
            )
            else -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES)
        }
        permissionResult = result
        requestPermissions(permissions, permissionRequestCode)
    }

    private fun openAppSettings(result: MethodChannel.Result) {
        try {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", packageName, null)
            }
            startActivity(intent)
            result.success(true)
        } catch (error: Exception) {
            result.error("settings_unavailable", "Android app settings are unavailable.", null)
        }
    }

    @Deprecated("Permission callback is required for the Flutter method channel.")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == permissionRequestCode) {
            val pending = permissionResult
            permissionResult = null
            pending?.success(permissionStatus())
        }
    }

    @Deprecated("MediaStore system request results are returned through onActivityResult.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        synchronized(operationLock) {
            val operationId = activePromptOperationId ?: return
            val token = activePromptToken ?: return
            if (requestCode != activePromptRequestCode) return
            try {
                val operation = readOperation() ?: return
                if (operation["id"]?.toString() != operationId ||
                    operation["batchToken"]?.toString() != token ||
                    operation["status"] != "awaitingSystemApproval") return
                val updated = operation.toMutableMap().apply {
                    this["status"] = "resultReceived"
                    this["resultCode"] = resultCode
                }
                if (persistOperation(updated, journalRevision(operation))) {
                    clearPromptReservation(operationId, token)
                }
            } catch (_: Exception) {
                // A damaged journal is never replaced by a callback-derived snapshot.
            }
        }
    }

    private fun acknowledgeSystemScreenClosed(operationId: String) {
        synchronized(operationLock) {
            if (activePromptOperationId == operationId) {
                activePromptOperationId = null
                activePromptToken = null
                activePromptRequestCode = null
                operationGate.release(operationId)
            }
        }
    }

    private fun clearPromptReservation(operationId: String, token: String) {
        synchronized(operationLock) {
            if (activePromptOperationId == operationId && activePromptToken == token) {
                activePromptOperationId = null
                activePromptToken = null
                activePromptRequestCode = null
                operationGate.release(operationId)
            }
        }
    }

    private fun releaseReservation(operationId: String) {
        synchronized(operationLock) {
            if (operationGate.current() == operationId && activePromptOperationId != operationId) {
                operationGate.release(operationId)
            }
        }
    }

    private fun permissionStatus(): Map<String, Any> {
        if (Build.VERSION.SDK_INT < 30) return mapOf("status" to "unsupported", "sdkInt" to Build.VERSION.SDK_INT)
        val full = if (Build.VERSION.SDK_INT <= 32) {
            checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        } else {
            checkSelfPermission(Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED
        }
        val selected = Build.VERSION.SDK_INT >= 34 &&
            checkSelfPermission(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) == PackageManager.PERMISSION_GRANTED
        val status = when {
            full -> "full"
            selected -> "limited"
            else -> "denied"
        }
        return mapOf("status" to status, "sdkInt" to Build.VERSION.SDK_INT)
    }

    private fun hasPhotoReadAccess(): Boolean {
        val status = permissionStatus()["status"] as String
        return status == "full" || status == "limited"
    }

    private fun saveReviewState(call: MethodCall, result: MethodChannel.Result) {
        val encoded = call.argument<String>("state")
        if (encoded == null || encoded.length > 8_000_000) {
            result.error("invalid_state", "Review state is missing or too large.", null)
            return
        }
        ioExecutor.execute {
            val committed = getPreferences().edit().putString(reviewStateKey, encoded).commit()
            deliver(result, committed)
        }
    }

    private fun queryPhotos(): List<Map<String, Any?>> {
        val rows = mutableListOf<Map<String, Any?>>()
        val projection = arrayOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.MIME_TYPE,
            MediaStore.Images.Media.DATE_TAKEN,
            MediaStore.Images.Media.DATE_ADDED,
            MediaStore.Images.Media.SIZE,
            MediaStore.Images.Media.BUCKET_ID,
            MediaStore.Images.Media.BUCKET_DISPLAY_NAME,
            MediaStore.Images.Media.RELATIVE_PATH,
            MediaStore.Images.Media.VOLUME_NAME,
            MediaStore.MediaColumns.GENERATION_ADDED,
            MediaStore.MediaColumns.GENERATION_MODIFIED,
        )
        val volumes = try {
            MediaStore.getExternalVolumeNames(this).sorted()
        } catch (_: SecurityException) {
            emptyList()
        }
        for (volume in volumes) {
            val collection = MediaStore.Images.Media.getContentUri(volume)
            val volumeVersion = try {
                MediaStore.getVersion(this, volume)
            } catch (_: Exception) {
                null
            }
            if (volumeVersion.isNullOrBlank()) continue
            val query = Bundle().apply {
                putString(ContentResolver.QUERY_ARG_SQL_SELECTION, "${MediaStore.MediaColumns.IS_TRASHED} = ?")
                putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, arrayOf("0"))
                putString(ContentResolver.QUERY_ARG_SQL_SORT_ORDER,
                    "${MediaStore.Images.Media.DATE_TAKEN} DESC, ${MediaStore.Images.Media.DATE_ADDED} DESC")
                putInt(MediaStore.QUERY_ARG_MATCH_TRASHED, MediaStoreIdentity.MATCH_EXCLUDE)
            }
            try {
                contentResolver.query(collection, projection, query, null)?.use { cursor ->
                    val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
                    val nameColumn = cursor.getColumnIndex(MediaStore.Images.Media.DISPLAY_NAME)
                    val mimeColumn = cursor.getColumnIndex(MediaStore.Images.Media.MIME_TYPE)
                    val takenColumn = cursor.getColumnIndex(MediaStore.Images.Media.DATE_TAKEN)
                    val addedColumn = cursor.getColumnIndex(MediaStore.Images.Media.DATE_ADDED)
                    val sizeColumn = cursor.getColumnIndex(MediaStore.Images.Media.SIZE)
                    val bucketColumn = cursor.getColumnIndex(MediaStore.Images.Media.BUCKET_DISPLAY_NAME)
                    val pathColumn = cursor.getColumnIndex(MediaStore.Images.Media.RELATIVE_PATH)
                    val volumeColumn = cursor.getColumnIndex(MediaStore.Images.Media.VOLUME_NAME)
                    val generationAddedColumn = cursor.getColumnIndex(MediaStore.MediaColumns.GENERATION_ADDED)
                    val generationModifiedColumn = cursor.getColumnIndex(MediaStore.MediaColumns.GENERATION_MODIFIED)
                    while (cursor.moveToNext()) {
                        val id = cursor.getLong(idColumn)
                        val rowVolume = stringAt(cursor, volumeColumn) ?: volume
                        val rowVersion = try { MediaStore.getVersion(this, rowVolume) } catch (_: Exception) { null }
                        val generationAdded = nullableLongAt(cursor, generationAddedColumn)
                        val generationModified = nullableLongAt(cursor, generationModifiedColumn)
                        if (rowVersion.isNullOrBlank() || generationAdded == null || generationModified == null) continue
                        val uri = ContentUris.withAppendedId(MediaStore.Images.Media.getContentUri(rowVolume), id)
                        val displayName = stringAt(cursor, nameColumn) ?: "Untitled photo"
                        val relativePath = stringAt(cursor, pathColumn)
                        val album = stringAt(cursor, bucketColumn)
                        val pathHint = "${relativePath.orEmpty()} ${album.orEmpty()}".lowercase()
                        val rawTaken = longAt(cursor, takenColumn)
                        val addedSeconds = longAt(cursor, addedColumn)
                        val captureMillis = rawTaken.takeIf { it > 0L }
                            ?: addedSeconds.takeIf { it > 0L }?.times(1000L)
                        val stableId = "$uri#version=${Uri.encode(rowVersion)}&added=$generationAdded"
                        rows.add(
                            mapOf(
                                "id" to stableId,
                                "uri" to uri.toString(),
                                "volumeName" to rowVolume,
                                "volumeVersion" to rowVersion,
                                "mediaId" to id,
                                "generationAdded" to generationAdded,
                                "generationModified" to generationModified,
                                "title" to displayName,
                                "album" to album,
                                "relativePath" to relativePath,
                                "dateTakenMillis" to captureMillis,
                                "sizeBytes" to longAt(cursor, sizeColumn).takeIf { it > 0L },
                                "screenshotHeuristic" to pathHint.contains("screenshot"),
                                "mimeType" to stringAt(cursor, mimeColumn),
                            ),
                        )
                    }
                }
            } catch (_: SecurityException) {
                // Limited access can change while a query is running. Hidden items are never deletion evidence.
            } catch (_: IllegalArgumentException) {
                // A provider rejecting an optional column yields no actionable identity for that volume.
            }
        }
        return rows.sortedByDescending { it["dateTakenMillis"] as? Long ?: 0L }
    }

    /**
     * Source detail is decoded from the exact validated MediaStore URI and is capped to the
     * displayed pixel budget. Grid/prefetch remains on the cheaper provider thumbnail path.
     */
    private fun loadPhotoImage(
        asset: Map<String, Any?>,
        requestedEdge: Int,
        sourceDetail: Boolean,
    ): Map<String, Any?>? {
        if (!hasPhotoReadAccess()) return null
        val uri = validatedUri(asset) ?: return null
        if (!isCurrentPhotoIdentity(asset)) return null
        val edge = requestedEdge.coerceIn(96, PhotoImagePolicy.MAX_EDGE_PX)

        var bitmap: Bitmap? = null
        var fromSource = false
        if (sourceDetail) {
            bitmap = try {
                tracePhotoSection("Hirang.photo.source_decode") {
                    decodeSourceBitmap(uri, edge).also { fromSource = it != null }
                }
            } catch (_: SecurityException) {
                return null
            } catch (_: Exception) {
                // An unsupported or damaged source can still have a usable provider preview.
                null
            }
        }
        if (bitmap == null) {
            if (!hasPhotoReadAccess() || !isCurrentPhotoIdentity(asset)) return null
            bitmap = try {
                tracePhotoSection("Hirang.photo.preview_decode") {
                    contentResolver.loadThumbnail(uri, Size(edge, edge), CancellationSignal())
                }
            } catch (_: SecurityException) {
                return null
            } catch (_: Exception) {
                return null
            }
        }

        val decoded = bitmap ?: return null
        var bounded: Bitmap? = null
        try {
            // The provider is allowed to return a different size. Never let that exceed our cap.
            val target = PhotoImagePolicy.targetSize(decoded.width, decoded.height, edge) ?: return null
            bounded = if (target.width == decoded.width && target.height == decoded.height) {
                decoded
            } else {
                Bitmap.createScaledBitmap(decoded, target.width, target.height, true)
            }
            // A permission revocation, replacement, or edit during decode invalidates these bytes.
            if (!hasPhotoReadAccess() || !isCurrentPhotoIdentity(asset)) return null
            val bytes = tracePhotoSection("Hirang.photo.encode") {
                encodeBoundedBitmap(bounded)
            } ?: return null
            // Compression can be expensive for detailed lossless previews; discard these bytes
            // too if access was revoked or the exact media generation changed while encoding.
            if (!hasPhotoReadAccess() || !isCurrentPhotoIdentity(asset)) return null
            return mapOf(
                "bytes" to bytes,
                "width" to bounded.width,
                "height" to bounded.height,
                "quality" to if (fromSource) "source" else "preview",
            )
        } finally {
            bounded?.recycle()
            if (bounded !== decoded) decoded.recycle()
        }
    }

    private fun decodeSourceBitmap(uri: Uri, requestedEdge: Int): Bitmap =
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(contentResolver, uri)) { decoder, info, _ ->
            val target = PhotoImagePolicy.targetSize(
                info.size.width,
                info.size.height,
                requestedEdge,
            ) ?: throw IllegalArgumentException("Invalid photo dimensions.")
            decoder.setTargetSize(target.width, target.height)
            decoder.setAllocator(ImageDecoder.ALLOCATOR_SOFTWARE)
        }

    private fun encodeBoundedBitmap(bitmap: Bitmap): ByteArray? {
        fun encode(format: Bitmap.CompressFormat, quality: Int): ByteArray? = try {
            val output = BoundedImageOutputStream()
            if (!bitmap.compress(format, quality, output)) return null
            output.toByteArray().takeIf { bytes -> PhotoImagePolicy.acceptsEncodedSize(bytes.size) }
        } catch (_: ImageOutputLimitException) {
            null
        } catch (_: IllegalArgumentException) {
            null
        } catch (_: RuntimeException) {
            null
        }

        // Lossless WebP avoids introducing another JPEG-generation step for card/detail images.
        return encode(Bitmap.CompressFormat.WEBP_LOSSLESS, 100)
            ?: encode(Bitmap.CompressFormat.WEBP_LOSSY, 95)
    }

    private fun isCurrentPhotoIdentity(asset: Map<String, Any?>): Boolean {
        if (!hasPhotoReadAccess()) return false
        val uri = validatedUri(asset) ?: return false
        val id = asset["mediaId"].asLong() ?: return false
        val volume = asset["volumeName"]?.toString() ?: return false
        return try {
            uri == ContentUris.withAppendedId(MediaStore.Images.Media.getContentUri(volume), id) &&
                queryIdentity(MediaStore.Images.Media.getContentUri(volume), id, asset, trashed = false) == "match"
        } catch (_: SecurityException) {
            false
        } catch (_: Exception) {
            false
        }
    }

    private fun assetStatus(asset: Map<String, Any?>): String {
        if (!hasPhotoReadAccess()) return "unknown"
        val uri = validatedUri(asset) ?: return "unknown"
        val id = asset["mediaId"].asLong() ?: return "unknown"
        val volume = asset["volumeName"]?.toString() ?: return "unknown"
        val collection = MediaStore.Images.Media.getContentUri(volume)
        return try {
            val present = queryIdentity(collection, id, asset, trashed = false)
            if (present == "match") return "present"
            if (present == "changed") return "changed"
            val trashed = queryIdentity(collection, id, asset, trashed = true)
            when (trashed) {
                "match" -> "trashed"
                "changed" -> "changed"
                else -> "unknown"
            }
        } catch (_: SecurityException) {
            "unknown"
        } catch (_: IllegalArgumentException) {
            "unknown"
        } catch (_: Exception) {
            "unknown"
        }
    }

    /** Returns match, changed, or absent; absence is intentionally mapped to unknown. */
    private fun queryIdentity(
        collection: Uri,
        id: Long,
        expected: Map<String, Any?>,
        trashed: Boolean,
    ): String {
        val projection = arrayOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.DATE_TAKEN,
            MediaStore.Images.Media.DATE_ADDED,
            MediaStore.Images.Media.SIZE,
            MediaStore.Images.Media.BUCKET_DISPLAY_NAME,
            MediaStore.Images.Media.RELATIVE_PATH,
            MediaStore.Images.Media.VOLUME_NAME,
            MediaStore.MediaColumns.GENERATION_ADDED,
            MediaStore.MediaColumns.GENERATION_MODIFIED,
        )
        val plan = MediaStoreIdentity.queryPlan(id, trashed)
        val query = Bundle().apply {
            putString(ContentResolver.QUERY_ARG_SQL_SELECTION, plan.selection)
            putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, plan.selectionArgs.toTypedArray())
            putInt(MediaStore.QUERY_ARG_MATCH_TRASHED, plan.matchTrashed)
        }
        contentResolver.query(collection, projection, query, null)?.use { cursor ->
            if (!cursor.moveToFirst()) return "absent"
            val observedVolume = stringAt(cursor, cursor.getColumnIndex(MediaStore.Images.Media.VOLUME_NAME))
            val volumeVersion = observedVolume?.let {
                try { MediaStore.getVersion(this, it) } catch (_: Exception) { null }
            }
            val row = mapOf(
                "volumeName" to observedVolume,
                "volumeVersion" to volumeVersion,
                "mediaId" to nullableLongAt(cursor, cursor.getColumnIndex(MediaStore.Images.Media._ID)),
                "generationAdded" to nullableLongAt(cursor, cursor.getColumnIndex(MediaStore.MediaColumns.GENERATION_ADDED)),
                "title" to stringAt(cursor, cursor.getColumnIndex(MediaStore.Images.Media.DISPLAY_NAME)),
                "dateTakenMillis" to effectiveDateMillis(
                    longAt(cursor, cursor.getColumnIndex(MediaStore.Images.Media.DATE_TAKEN)),
                    longAt(cursor, cursor.getColumnIndex(MediaStore.Images.Media.DATE_ADDED)),
                ),
                "sizeBytes" to longAt(cursor, cursor.getColumnIndex(MediaStore.Images.Media.SIZE)).takeIf { it > 0L },
                "album" to stringAt(cursor, cursor.getColumnIndex(MediaStore.Images.Media.BUCKET_DISPLAY_NAME)),
                "relativePath" to stringAt(cursor, cursor.getColumnIndex(MediaStore.Images.Media.RELATIVE_PATH)),
                "generationModified" to nullableLongAt(cursor, cursor.getColumnIndex(MediaStore.MediaColumns.GENERATION_MODIFIED)),
            )
            val matches = if (trashed) {
                MediaStoreIdentity.matchesAfterTrash(expected, row)
            } else {
                MediaStoreIdentity.matchesBeforeMutation(expected, row)
            }
            return if (matches) "match" else "changed"
        }
        return "absent"
    }

    private fun effectiveDateMillis(taken: Long, addedSeconds: Long): Long? =
        taken.takeIf { it > 0L } ?: addedSeconds.takeIf { it > 0L }?.times(1000L)

    private fun validatedUri(asset: Map<String, Any?>): Uri? {
        val raw = asset["uri"]?.toString() ?: return null
        val id = asset["mediaId"].asLong() ?: return null
        val volume = asset["volumeName"]?.toString() ?: return null
        val version = asset["volumeVersion"]?.toString()?.takeIf { it.isNotBlank() } ?: return null
        val added = asset["generationAdded"].asLong() ?: return null
        val modified = asset["generationModified"].asLong() ?: return null
        if (id <= 0L || volume.isBlank() || added <= 0L || modified <= 0L) return null
        val availableVolumes = try {
            MediaStore.getExternalVolumeNames(this)
        } catch (_: Exception) {
            return null
        }
        if (!availableVolumes.contains(volume)) return null
        val supplied = try {
            Uri.parse(raw)
        } catch (_: Exception) {
            return null
        }
        // Destructive requests use the volume-specific item URI, never VOLUME_EXTERNAL's synthetic URI.
        val exact = ContentUris.withAppendedId(MediaStore.Images.Media.getContentUri(volume), id)
        val stableId = "$exact#version=${Uri.encode(version)}&added=$added"
        if (supplied != exact || supplied.authority != "media" || asset["id"]?.toString() != stableId) return null
        return exact
    }

    private fun beginTrashOperation(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 30) {
            result.error("unsupported", "Recoverable system trash requires Android 11 or later.", null)
            return
        }
        val operationId = call.argument<String>("operationId")?.trim().orEmpty()
        val items = call.argument<List<Map<String, Any?>>>("items") ?: emptyList()
        if (operationId.isBlank() || operationId.length > 128 || items.isEmpty() || items.size > maxOperationItems) {
            result.error("invalid_operation", "The selected photo list is invalid or too large.", null)
            return
        }
        var expectedJournal = TrashJournalRevision(null, 0L)
        synchronized(operationLock) {
            val current = try {
                readOperation()
            } catch (_: Exception) {
                result.error("journal_unreadable", "The saved system-trash status could not be read.", null)
                return
            }
            if (activePromptOperationId != null ||
                current?.get("status")?.let { it in activeOperationStatuses } == true ||
                !operationGate.tryReserve(operationId)) {
                result.error("operation_busy", "Another trash operation is still active.", null)
                return
            }
            expectedJournal = journalRevision(current)
            // Reservation occurs synchronously before dispatching I/O; duplicate taps are rejected.
        }
        ioExecutor.execute {
            try {
                if (!hasPhotoReadAccess()) {
                    releaseReservation(operationId)
                    deliverError(result, "access_changed", "Photo access changed before the system request.")
                    return@execute
                }
                val outcomes = mutableMapOf<String, String>()
                val eligible = mutableListOf<String>()
                val uniqueItems = linkedMapOf<String, Map<String, Any?>>()
                for (item in items) {
                    val itemId = item["id"]?.toString().orEmpty()
                    if (itemId.isBlank() || uniqueItems.containsKey(itemId)) {
                        releaseReservation(operationId)
                        deliverError(result, "invalid_items", "Photo identifiers must be present and unique.")
                        return@execute
                    }
                    if (validatedUri(item) == null) {
                        releaseReservation(operationId)
                        deliverError(result, "invalid_uri", "A selected item is not a volume-specific MediaStore image.")
                        return@execute
                    }
                    uniqueItems[itemId] = item
                    when (assetStatus(item)) {
                        "present" -> {
                            eligible.add(itemId)
                            outcomes[itemId] = "pending"
                        }
                        "trashed" -> outcomes[itemId] = "trashed"
                        else -> outcomes[itemId] = "unknown"
                    }
                }
                val operation = mutableMapOf<String, Any?>(
                    "id" to operationId,
                    "status" to if (eligible.isEmpty()) "interrupted" else "prepared",
                    "items" to uniqueItems.values.toList(),
                    "candidateIds" to eligible,
                    "outcomes" to outcomes,
                    "nextBatchStart" to 0,
                    "currentBatchCount" to 0,
                    "currentBatchEnd" to 0,
                    "currentBatchIds" to emptyList<String>(),
                    "resultCode" to null,
                    "batchToken" to null,
                    "requestCode" to null,
                )
                if (!persistOperation(operation, expectedJournal)) {
                    releaseReservation(operationId)
                    deliverError(result, "journal_failed", "The operation could not be saved safely.")
                    return@execute
                }
                if (eligible.isEmpty()) {
                    releaseReservation(operationId)
                    deliver(result, operation)
                } else {
                    launchBatch(operationId, result)
                }
            } catch (error: Exception) {
                bestEffortInterruptJournal(operationId)
                releaseReservation(operationId)
                deliverError(result, "trash_prepare_failed", error.message ?: "Hirang could not prepare the operation safely.")
            }
        }
    }

    private fun continueTrashOperation(call: MethodCall, result: MethodChannel.Result) {
        val operationId = call.argument<String>("operationId")?.trim().orEmpty()
        synchronized(operationLock) {
            val operation = try {
                readOperation()
            } catch (_: Exception) {
                result.error("journal_unreadable", "The saved system-trash status could not be read.", null)
                return
            }
            if (activePromptOperationId != null || operation == null ||
                operation["id"] != operationId || operation["status"] != "needsContinue" ||
                !operationGate.tryReserve(operationId)) {
                result.error("operation_state", "There is no confirmed batch waiting to continue.", null)
                return
            }
        }
        launchBatch(operationId, result)
    }

    private fun launchBatch(operationId: String, result: MethodChannel.Result) {
        ioExecutor.execute {
            try {
                val operation = readOperation()
                if (operation == null || operation["id"] != operationId ||
                    operation["status"] !in setOf("prepared", "needsContinue")) {
                    releaseReservation(operationId)
                    deliverError(result, "operation_missing", "The saved operation is not ready for another system request.")
                    return@execute
                }
                if (!hasPhotoReadAccess()) {
                    bestEffortInterruptJournal(operationId)
                    releaseReservation(operationId)
                    deliverError(result, "access_changed", "Photo access changed before the system request.")
                    return@execute
                }
                val candidates = (operation["candidateIds"] as? List<*>)?.map { it.toString() } ?: emptyList()
                val items = (operation["items"] as? List<*>)
                    ?.mapNotNull { it as? Map<String, Any?> }
                    ?.associateBy { it["id"]?.toString().orEmpty() }
                    ?: emptyMap()
                val start = (operation["nextBatchStart"] as? Number)?.toInt() ?: 0
                val end = min(start + batchSize, candidates.size)
                if (start >= end) {
                    val terminal = operation.toMutableMap().apply { this["status"] = "complete" }
                    if (!persistOperation(terminal, journalRevision(operation))) {
                        releaseReservation(operationId)
                        deliverError(result, "operation_stale", "The saved operation changed before this batch could finish.")
                        return@execute
                    }
                    releaseReservation(operationId)
                    deliver(result, terminal)
                    return@execute
                }
                val outcomes = mutableMapOf<String, String>().apply {
                    putAll((operation["outcomes"] as? Map<*, *>)?.entries?.associate { it.key.toString() to it.value.toString() } ?: emptyMap())
                }
                val submittedIds = mutableListOf<String>()
                val requestUris = mutableListOf<Uri>()
                for (itemId in candidates.subList(start, end)) {
                    val asset = items[itemId]
                    if (asset == null) {
                        outcomes[itemId] = "unknown"
                        continue
                    }
                    when (assetStatus(asset)) {
                        "present" -> {
                            val uri = validatedUri(asset)
                            if (uri == null) outcomes[itemId] = "unknown" else {
                                submittedIds.add(itemId)
                                requestUris.add(uri)
                            }
                        }
                        "trashed" -> outcomes[itemId] = "trashed"
                        else -> outcomes[itemId] = "unknown"
                    }
                }
                if (requestUris.isEmpty()) {
                    val stopped = operation.toMutableMap().apply {
                        this["outcomes"] = outcomes
                        this["currentBatchCount"] = 0
                        this["currentBatchEnd"] = end
                        this["currentBatchIds"] = emptyList<String>()
                        this["status"] = "interrupted"
                    }
                    if (!persistOperation(stopped, journalRevision(operation))) {
                        releaseReservation(operationId)
                        deliverError(result, "operation_stale", "The saved operation changed during revalidation.")
                        return@execute
                    }
                    releaseReservation(operationId)
                    deliver(result, stopped)
                    return@execute
                }
                val pendingIntent = try {
                    MediaStore.createTrashRequest(contentResolver, requestUris, true)
                } catch (_: SecurityException) {
                    bestEffortInterruptJournal(operationId, outcomes)
                    releaseReservation(operationId)
                    deliverError(result, "trash_request_denied", "Android did not allow a recoverable trash request for these items.")
                    return@execute
                } catch (_: Exception) {
                    bestEffortInterruptJournal(operationId, outcomes)
                    releaseReservation(operationId)
                    deliverError(result, "trash_request_failed", "Android could not prepare the recoverable trash request.")
                    return@execute
                }
                val token = java.util.UUID.randomUUID().toString()
                val requestCode = 10_000 + ((operationId.hashCode() xor System.nanoTime().toInt()) and 0x3fff)
                val updated = operation.toMutableMap().apply {
                    this["outcomes"] = outcomes
                    this["status"] = "awaitingSystemApproval"
                    this["nextBatchStart"] = start
                    this["currentBatchCount"] = submittedIds.size
                    this["currentBatchEnd"] = end
                    this["currentBatchIds"] = submittedIds
                    this["resultCode"] = null
                    this["batchToken"] = token
                    this["requestCode"] = requestCode
                }
                if (!persistOperation(updated)) {
                    releaseReservation(operationId)
                    deliverError(result, "journal_failed", "The operation could not be saved before Android approval.")
                    return@execute
                }
                mainHandler.post {
                    try {
                        synchronized(operationLock) {
                            val current = readOperation()
                            if (!operationGate.isReserved(operationId) || current?.get("id") != operationId ||
                                current["status"] != "awaitingSystemApproval" || current["batchToken"] != token) {
                                releaseReservation(operationId)
                                result.error("operation_stale", "This system request was superseded before launch.", null)
                                return@post
                            }
                            activePromptOperationId = operationId
                            activePromptToken = token
                            activePromptRequestCode = requestCode
                        }
                        startIntentSenderForResult(pendingIntent.intentSender, requestCode, null, 0, 0, 0)
                        result.success(updated)
                    } catch (_: Exception) {
                        bestEffortInterruptJournal(operationId, outcomes)
                        clearPromptReservation(operationId, token)
                        releaseReservation(operationId)
                        result.error("trash_launch_failed", "Android could not open its recoverable trash confirmation.", null)
                    }
                }
            } catch (error: Exception) {
                bestEffortInterruptJournal(operationId)
                releaseReservation(operationId)
                deliverError(result, "trash_prepare_failed", error.message ?: "Hirang could not prepare the operation safely.")
            }
        }
    }

    private fun reconcileOperation(operationId: String, afterSystemScreenClosed: Boolean): Map<String, Any?>? {
        val operation = readOperation() ?: return null
        if (operationId.isNotBlank() && operation["id"] != operationId) return operation
        val status = operation["status"]?.toString() ?: "unknown"
        if (status == "awaitingSystemApproval" && !afterSystemScreenClosed) return operation
        if (status !in setOf("resultReceived", "awaitingSystemApproval", "prepared")) return operation
        val candidates = (operation["candidateIds"] as? List<*>)?.map { it.toString() } ?: emptyList()
        val items = (operation["items"] as? List<*>)
            ?.mapNotNull { it as? Map<String, Any?> }
            ?.associateBy { it["id"]?.toString().orEmpty() }
            ?: emptyMap()
        val start = (operation["nextBatchStart"] as? Number)?.toInt() ?: 0
        val end = (operation["currentBatchEnd"] as? Number)?.toInt() ?: start
        val resultCode = (operation["resultCode"] as? Number)?.toInt()
        val interrupted = status != "resultReceived"
        val submittedIds = (operation["currentBatchIds"] as? List<*>)?.map { it.toString() }
            ?: emptyList()
        val outcomes = mutableMapOf<String, String>().apply {
            putAll((operation["outcomes"] as? Map<*, *>)?.entries?.associate { it.key.toString() to it.value.toString() } ?: emptyMap())
        }
        val affectedIds = when {
            status == "prepared" -> candidates
            submittedIds.isNotEmpty() -> submittedIds
            else -> emptyList()
        }
        for (itemId in affectedIds) {
            val asset = items[itemId]
            if (asset == null) {
                outcomes[itemId] = "unknown"
                continue
            }
            when (assetStatus(asset)) {
                "trashed" -> outcomes[itemId] = "trashed"
                "present" -> outcomes[itemId] = when {
                    status == "resultReceived" && resultCode == Activity.RESULT_OK -> "stillPresent"
                    status == "resultReceived" -> "cancelled"
                    else -> "unknown"
                }
                else -> outcomes[itemId] = "unknown"
            }
        }
        val nextIndex = if (!interrupted && resultCode == Activity.RESULT_OK) end else start
        val nextStatus = when {
            status == "prepared" || status == "awaitingSystemApproval" -> "interrupted"
            resultCode != Activity.RESULT_OK -> "cancelled"
            nextIndex >= candidates.size -> "complete"
            else -> "needsContinue"
        }
        val updated = operation.toMutableMap().apply {
            this["outcomes"] = outcomes
            this["status"] = nextStatus
            this["nextBatchStart"] = nextIndex
            this["currentBatchCount"] = 0
            this["currentBatchIds"] = emptyList<String>()
            this["resultCode"] = resultCode
        }
        if (!persistOperation(updated, journalRevision(operation))) {
            // Another callback/operation committed while provider rows were being checked.
            // Return the latest durable snapshot and never overwrite it with stale outcomes.
            return readOperation()
        }
        releaseReservation(operation["id"]?.toString().orEmpty())
        return updated
    }

    private fun interruptJournal(operationId: String, priorOutcomes: Map<String, String>? = null) {
        val operation = readOperation() ?: return
        if (operation["id"]?.toString() != operationId) return
        val outcomes = mutableMapOf<String, String>().apply {
            putAll((priorOutcomes ?: (operation["outcomes"] as? Map<*, *>)
                ?.entries?.associate { it.key.toString() to it.value.toString() } ?: emptyMap()))
            entries.toList().forEach { (key, value) -> if (value == "pending") this[key] = "unknown" }
        }
        val interrupted = operation.toMutableMap().apply {
            this["outcomes"] = outcomes
            this["status"] = "interrupted"
            this["currentBatchIds"] = emptyList<String>()
            this["currentBatchCount"] = 0
        }
        persistOperation(interrupted)
    }

    /** Damaged journals remain untouched, but a failed best-effort update must not strand a caller. */
    private fun bestEffortInterruptJournal(operationId: String, priorOutcomes: Map<String, String>? = null) {
        try {
            interruptJournal(operationId, priorOutcomes)
        } catch (_: Exception) {
            // Fail closed: preserve the unreadable bytes and let the caller see the original failure.
        }
    }

    private fun clearTrashOperation(call: MethodCall, result: MethodChannel.Result) {
        val expectedId = call.argument<String>("operationId")?.trim().orEmpty()
        if (expectedId.isBlank()) {
            result.error("operation_id_required", "A result journal ID is required before it can be cleared.", null)
            return
        }
        val reservation = "clear:$expectedId"
        var expectedJournal = TrashJournalRevision(null, 0L)
        synchronized(operationLock) {
            val current = try {
                readOperation()
            } catch (_: Exception) {
                result.error("journal_unreadable", "The saved system-trash status could not be read.", null)
                return
            }
            if (activePromptOperationId != null || current == null ||
                current["id"]?.toString() != expectedId || current["status"]?.toString() in activeOperationStatuses ||
                !operationGate.tryReserve(reservation)) {
                result.error("operation_active", "The expected finished result is not safe to clear.", null)
                return
            }
            expectedJournal = journalRevision(current)
        }
        ioExecutor.execute {
            var journalUnreadable = false
            val cleared = synchronized(operationLock) {
                val current = try {
                    readOperation()
                } catch (_: Exception) {
                    journalUnreadable = true
                    operationGate.release(reservation)
                    null
                }
                if (journalUnreadable) return@synchronized null
                if (!operationGate.isReserved(reservation) || activePromptOperationId != null || current == null ||
                    current["id"]?.toString() != expectedId || current["status"]?.toString() in activeOperationStatuses ||
                    journalRevision(current) != expectedJournal) {
                    operationGate.release(reservation)
                    null
                } else {
                    val committed = getPreferences().edit().remove(operationKey).commit()
                    operationGate.release(reservation)
                    committed
                }
            }
            if (journalUnreadable) {
                deliverError(result, "journal_unreadable", "The saved system-trash status could not be read.")
            } else if (cleared == null) {
                deliverError(result, "operation_changed", "The operation changed before its result could be cleared.")
            } else {
                deliver(result, cleared)
            }
        }
    }

    private fun readOperation(): Map<String, Any?>? {
        return synchronized(operationLock) {
            val preferences = getPreferences()
            if (!preferences.contains(operationKey)) return@synchronized null
            val encoded = preferences.getString(operationKey, null)
                ?: throw IllegalStateException("The saved system-trash record is unreadable.")
            val decoded = try {
                jsonObjectToMap(JSONObject(encoded))
            } catch (error: Exception) {
                throw IllegalStateException("The saved system-trash record is unreadable.", error)
            }
            TrashJournalRecord.validate(decoded)
        }
    }

    private fun journalRevision(operation: Map<String, Any?>?): TrashJournalRevision =
        TrashJournalRevision(
            operation?.get("id")?.toString(),
            (operation?.get("revision") as? Number)?.toLong() ?: 0L,
        )

    private fun persistOperation(
        operation: Map<String, Any?>,
        expected: TrashJournalRevision = journalRevision(operation),
    ): Boolean = synchronized(operationLock) {
        val current = journalRevision(readOperation())
        if (!TrashJournalRevisionGuard.canCommit(expected, current)) return@synchronized false
        val durable = operation.toMutableMap().apply { this["revision"] = current.revision + 1L }
        getPreferences().edit().putString(operationKey, JSONObject(durable).toString()).commit()
    }

    private fun getPreferences() = getSharedPreferences(preferencesName, MODE_PRIVATE)

    private fun runImageIo(result: MethodChannel.Result, block: () -> Any?) {
        val traceCookie = imageTraceCookie.incrementAndGet()
        if (photoTimingEnabled) Trace.beginAsyncSection("Hirang.photo.queue", traceCookie)
        try {
            imageExecutor.execute {
                if (photoTimingEnabled) Trace.endAsyncSection("Hirang.photo.queue", traceCookie)
                try {
                    deliver(result, block())
                } catch (error: Exception) {
                    deliverError(result, "image_error", error.message ?: "The photo preview could not be decoded.")
                }
            }
        } catch (_: RejectedExecutionException) {
            if (photoTimingEnabled) Trace.endAsyncSection("Hirang.photo.queue", traceCookie)
            deliverError(result, "image_busy", "Photo previews are still loading. Please retry shortly.")
        }
    }

    private inline fun <T> tracePhotoSection(name: String, block: () -> T): T {
        if (!photoTimingEnabled) return block()
        Trace.beginSection(name)
        try {
            return block()
        } finally {
            Trace.endSection()
        }
    }

    private fun runIo(result: MethodChannel.Result, block: () -> Any?) {
        ioExecutor.execute {
            try {
                deliver(result, block())
            } catch (error: Exception) {
                deliverError(result, "media_error", error.message ?: "The photo provider could not complete the request.")
            }
        }
    }

    private fun deliver(result: MethodChannel.Result, value: Any?) {
        mainHandler.post { result.success(value) }
    }

    private fun deliverError(result: MethodChannel.Result, code: String, message: String) {
        mainHandler.post { result.error(code, message, null) }
    }

    private fun stringAt(cursor: android.database.Cursor, column: Int): String? =
        if (column < 0 || cursor.isNull(column)) null else cursor.getString(column)

    private fun longAt(cursor: android.database.Cursor, column: Int): Long =
        if (column < 0 || cursor.isNull(column)) 0L else cursor.getLong(column)

    private fun nullableLongAt(cursor: android.database.Cursor, column: Int): Long? =
        if (column < 0 || cursor.isNull(column)) null else cursor.getLong(column)

    private fun Any?.asLong(): Long? = (this as? Number)?.toLong()

    private fun jsonObjectToMap(value: JSONObject): Map<String, Any?> =
        value.keys().asSequence().associateWith { key -> jsonValue(value.opt(key)) }

    private fun jsonValue(value: Any?): Any? = when (value) {
        JSONObject.NULL -> null
        is JSONObject -> jsonObjectToMap(value)
        is JSONArray -> (0 until value.length()).map { jsonValue(value.opt(it)) }
        else -> value
    }

    companion object {
        private val activeOperationStatuses = setOf(
            "prepared", "awaitingSystemApproval", "resultReceived", "needsContinue", "reconciling",
        )
    }
}
