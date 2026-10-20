package com.francisgiann.hirang

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoPageQueryContractTest {
    @Test
    fun largestPhotoSortUsesDescendingSizeAndEveryStableTieBreaker() {
        assertEquals(
            "_size DESC, volume_name DESC, _id DESC",
            PhotoPageQueryContract.sortOrder("largestKnown"),
        )
    }

    @Test
    fun recentPhotoSortUsesExplicitDescendingDateAndIdentityTieBreakers() {
        assertEquals(
            "CASE WHEN datetaken > 0 THEN datetaken WHEN date_added > 0 THEN date_added * 1000 ELSE 0 END DESC, date_added DESC, volume_name DESC, _id DESC",
            PhotoPageQueryContract.sortOrder("recent"),
        )
    }

    @Test
    fun observedPageBoundaryMustMoveStrictlyForwardInDescendingOrder() {
        assertTrue(boundary(currentPrimary = 9, previousPrimary = 10))
        assertFalse(boundary(currentPrimary = 11, previousPrimary = 10))
        assertFalse(boundary(currentVolume = "external_b", previousVolume = "external_a"))
        assertFalse(boundary(currentId = 8, previousId = 7))
    }

    @Test
    fun recentSortUsesCaptureDateThenDateAddedBeforeStableIdentity() {
        assertEquals(
            PhotoPageQueryContract.effectiveCaptureMillis(1_700_000_000_000, 1_600_000_000),
            PhotoPageQueryContract.effectiveCaptureMillis(0, 1_700_000_000),
        )
        assertEquals(0L, PhotoPageQueryContract.effectiveCaptureMillis(0, 0))
        assertTrue(boundary(currentPrimary = 100, previousPrimary = 100, currentSecondary = 2, previousSecondary = 3))
        assertTrue(boundary(currentPrimary = 100, previousPrimary = 100, currentSecondary = 3, previousSecondary = 3,
            currentVolume = "external_a", previousVolume = "external_b"))
        assertTrue(boundary(currentPrimary = 100, previousPrimary = 100, currentSecondary = 3, previousSecondary = 3,
            currentVolume = "external_b", previousVolume = "external_b", currentId = 6, previousId = 7))
    }

    private fun boundary(
        currentPrimary: Long = 10,
        previousPrimary: Long = 10,
        currentSecondary: Long = 5,
        previousSecondary: Long = 5,
        currentVolume: String = "external_a",
        previousVolume: String = "external_a",
        currentId: Long = 7,
        previousId: Long = 8,
    ): Boolean = PhotoPageQueryContract.hasDescendingBoundary(
        currentPrimary = currentPrimary,
        currentSecondary = currentSecondary,
        currentVolume = currentVolume,
        currentId = currentId,
        previousPrimary = previousPrimary,
        previousSecondary = previousSecondary,
        previousVolume = previousVolume,
        previousId = previousId,
    )
}
