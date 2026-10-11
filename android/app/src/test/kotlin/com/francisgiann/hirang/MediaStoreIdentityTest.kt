package com.francisgiann.hirang

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaStoreIdentityTest {
    private val snapshot = mapOf<String, Any?>(
        "volumeName" to "external_primary",
        "volumeVersion" to "catalog-v1",
        "mediaId" to 42L,
        "generationAdded" to 18L,
        "generationModified" to 21L,
        "title" to "fixture.jpg",
        "dateTakenMillis" to 1_700_000_000_000L,
        "sizeBytes" to 400L,
        "album" to "Fixture",
        "relativePath" to "Pictures/Fixture/",
    )

    @Test fun numericFieldsSurviveDartJsonIntLongRoundTrip() {
        val roundTrip = snapshot.toMutableMap().apply {
            this["mediaId"] = 42
            this["generationAdded"] = 18
            this["generationModified"] = 21
            this["sizeBytes"] = 400
        }
        assertTrue(MediaStoreIdentity.matchesBeforeMutation(snapshot, roundTrip))
    }

    @Test fun modifiedGenerationChangesOnlyInvalidatePreMutationSnapshot() {
        val afterTrash = snapshot.toMutableMap().apply { this["generationModified"] = 22L }
        assertFalse(MediaStoreIdentity.matchesBeforeMutation(snapshot, afterTrash))
        assertTrue(MediaStoreIdentity.matchesAfterTrash(snapshot, afterTrash))
    }

    @Test fun trashLookupExplicitlyIncludesOnlyTrashedItems() {
        val plan = MediaStoreIdentity.queryPlan(42, trashed = true)
        assertEquals(MediaStoreIdentity.MATCH_ONLY, plan.matchTrashed)
        assertEquals("_id = ? AND is_trashed = ?", plan.selection)
        assertEquals(listOf("42", "1"), plan.selectionArgs)
    }

    @Test fun previewIdentityIsRejectedWhenTheRowIsEditedDuringDecode() {
        val edited = snapshot.toMutableMap().apply { this["generationModified"] = 22L }
        assertFalse(MediaStoreIdentity.matchesBeforeMutation(snapshot, edited))
        assertTrue(MediaStoreIdentity.matchesAfterTrash(snapshot, edited))
    }

    @Test fun changedCatalogOrInsertionGenerationCannotReuseOldPreviewIdentity() {
        val newCatalog = snapshot.toMutableMap().apply { this["volumeVersion"] = "catalog-v2" }
        val replacement = snapshot.toMutableMap().apply { this["generationAdded"] = 19L }
        assertFalse(MediaStoreIdentity.matchesBeforeMutation(snapshot, newCatalog))
        assertFalse(MediaStoreIdentity.matchesBeforeMutation(snapshot, replacement))
    }

    @Test fun reusedMediaStoreRowIdDoesNotInheritSnapshotIdentity() {
        val replacement = snapshot.toMutableMap().apply { this["generationAdded"] = 19L }
        assertFalse(MediaStoreIdentity.matchesAfterTrash(snapshot, replacement))
    }
}
