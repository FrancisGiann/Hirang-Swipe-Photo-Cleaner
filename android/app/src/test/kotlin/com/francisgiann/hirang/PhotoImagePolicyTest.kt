package com.francisgiann.hirang

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoImagePolicyTest {
    @Test fun targetSizeKeepsPortraitAndLandscapeAspectWithinPixelBudget() {
        val portrait = PhotoImagePolicy.targetSize(3000, 4000, 2048)
        val landscape = PhotoImagePolicy.targetSize(6000, 4000, 2048)
        assertNotNull(portrait)
        assertNotNull(landscape)
        assertTrue(PhotoImagePolicy.isWithinBounds(portrait!!))
        assertTrue(PhotoImagePolicy.isWithinBounds(landscape!!))
        assertEquals(2000, portrait.height)
        assertEquals(1500, portrait.width)
        assertEquals(2048, landscape.width)
        assertEquals(1365, landscape.height)
    }

    @Test fun smallerSourceIsNeverUpscaledAndInvalidDimensionsFailClosed() {
        assertEquals(PhotoImagePolicy.PixelSize(800, 600), PhotoImagePolicy.targetSize(800, 600, 2048))
        assertNull(PhotoImagePolicy.targetSize(0, 600, 1024))
        assertNull(PhotoImagePolicy.targetSize(800, -1, 1024))
    }

    @Test fun oversizedSourceIsCappedByBothLongestEdgeAndDecodedPixels() {
        val target = PhotoImagePolicy.targetSize(12000, 9000, 5000)!!
        assertTrue(PhotoImagePolicy.isWithinBounds(target))
        assertTrue(target.longestEdge <= 2048)
        assertTrue(target.area <= 3_000_000L)
    }

    @Test fun encodedBudgetRejectsOversizeAndBoundedStreamNeverExceedsLimit() {
        assertTrue(PhotoImagePolicy.acceptsEncodedSize(PhotoImagePolicy.MAX_ENCODED_BYTES))
        assertFalse(PhotoImagePolicy.acceptsEncodedSize(PhotoImagePolicy.MAX_ENCODED_BYTES + 1))
        val stream = BoundedImageOutputStream(8)
        stream.write(ByteArray(8))
        assertEquals(8, stream.size())
        try {
            stream.write(1)
            throw AssertionError("expected bounded output failure")
        } catch (_: ImageOutputLimitException) {
            assertEquals(8, stream.size())
        }
    }
}
