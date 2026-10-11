package com.francisgiann.hirang

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Test

class TrashJournalRecordTest {
    @Test fun acceptsLegacyValidRecordWithoutRevision() {
        val legacy = mapOf<String, Any?>(
            "id" to "legacy-operation",
            "status" to "needsContinue",
            "items" to listOf(mapOf("id" to "photo-1")),
            "outcomes" to mapOf("photo-1" to "unknown"),
            "candidateIds" to listOf("photo-1"),
        )
        assertSame(legacy, TrashJournalRecord.validate(legacy))
        assertEquals("legacy-operation", TrashJournalRecord.validate(legacy)["id"])
    }

    @Test fun acceptsNonnegativeIntegralRevisionNumbers() {
        listOf<Any>(0, 7L, 12.0, 2.0f).forEach { revision ->
            val record = validRecord() + ("revision" to revision)
            assertEquals(revision, TrashJournalRecord.validate(record)["revision"])
        }
    }

    @Test fun rejectsPresentNullNegativeFractionalAndNonNumericRevisions() {
        listOf<Any?>(null, -1, -1L, 1.5, Double.NaN, Double.POSITIVE_INFINITY, "2").forEach { revision ->
            val record = validRecord() + ("revision" to revision)
            assertThrows(IllegalStateException::class.java) {
                TrashJournalRecord.validate(record)
            }
        }
    }

    @Test fun rejectsPresentButUndecodableOrStructurallyInvalidRecords() {
        val invalidRecords = listOf(
            emptyMap<String, Any?>(),
            mapOf("id" to "missing-status", "items" to emptyList<Any>(), "outcomes" to emptyMap<Any, Any>()),
            mapOf("id" to "unknown-status", "status" to "future-unknown"),
            mapOf("id" to "missing-items", "status" to "complete", "outcomes" to emptyMap<Any, Any>()),
        )
        invalidRecords.forEach { record ->
            assertThrows(IllegalStateException::class.java) {
                TrashJournalRecord.validate(record)
            }
        }
    }

    private fun validRecord(): Map<String, Any?> = mapOf(
        "id" to "journal-operation",
        "status" to "complete",
        "items" to emptyList<Any>(),
        "outcomes" to emptyMap<Any, Any>(),
    )
}
