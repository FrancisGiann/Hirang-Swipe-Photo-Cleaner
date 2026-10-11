package com.francisgiann.hirang

import java.io.ByteArrayOutputStream
import kotlin.math.floor
import kotlin.math.min
import kotlin.math.sqrt

/** Bounds transient image buffers before any large bitmap reaches Flutter. */
internal object PhotoImagePolicy {
    const val MAX_EDGE_PX = 2048
    const val MAX_BITMAP_PIXELS = 3_000_000L
    const val MAX_ENCODED_BYTES = 12 * 1024 * 1024
    const val PREVIEW_EDGE_PX = 512

    data class PixelSize(val width: Int, val height: Int) {
        val area: Long get() = width.toLong() * height.toLong()
        val longestEdge: Int get() = maxOf(width, height)
    }

    fun targetSize(sourceWidth: Int, sourceHeight: Int, requestedEdge: Int): PixelSize? {
        if (sourceWidth <= 0 || sourceHeight <= 0 || requestedEdge <= 0) return null
        val edge = requestedEdge.coerceIn(96, MAX_EDGE_PX)
        val sourceArea = sourceWidth.toLong() * sourceHeight.toLong()
        val scale = min(
            1.0,
            min(
                edge.toDouble() / maxOf(sourceWidth, sourceHeight),
                sqrt(MAX_BITMAP_PIXELS.toDouble() / sourceArea.toDouble()),
            ),
        )
        return PixelSize(
            floor(sourceWidth * scale).toInt().coerceAtLeast(1),
            floor(sourceHeight * scale).toInt().coerceAtLeast(1),
        )
    }

    fun isWithinBounds(size: PixelSize): Boolean =
        size.width > 0 && size.height > 0 &&
            size.longestEdge <= MAX_EDGE_PX && size.area <= MAX_BITMAP_PIXELS

    fun acceptsEncodedSize(bytes: Int): Boolean = bytes in 1..MAX_ENCODED_BYTES
}

/** A compressed image cannot grow without bound while crossing the method channel. */
internal class BoundedImageOutputStream(
    private val maximumBytes: Int = PhotoImagePolicy.MAX_ENCODED_BYTES,
) : ByteArrayOutputStream(64 * 1024) {
    override fun write(value: Int) {
        if (count >= maximumBytes) throw ImageOutputLimitException()
        super.write(value)
    }

    override fun write(buffer: ByteArray, offset: Int, length: Int) {
        if (length < 0 || count.toLong() + length > maximumBytes) {
            throw ImageOutputLimitException()
        }
        super.write(buffer, offset, length)
    }
}

internal class ImageOutputLimitException : RuntimeException("Encoded preview exceeded its memory budget.")
