package com.francisgiann.hirang

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TrashJournalRevisionGuardTest {
    @Test fun staleReconciliationCannotOverwriteClearedOrReplacementJournal() {
        val oldSnapshot = TrashJournalRevision("old-operation", 4)
        assertFalse(
            TrashJournalRevisionGuard.canCommit(
                oldSnapshot,
                TrashJournalRevision(null, 0),
            ),
        )
        assertFalse(
            TrashJournalRevisionGuard.canCommit(
                oldSnapshot,
                TrashJournalRevision("new-operation", 1),
            ),
        )
    }

    @Test fun concurrentUpdateOfSameOperationInvalidatesAnOlderSnapshot() {
        assertFalse(
            TrashJournalRevisionGuard.canCommit(
                TrashJournalRevision("same-operation", 8),
                TrashJournalRevision("same-operation", 9),
            ),
        )
        assertTrue(
            TrashJournalRevisionGuard.canCommit(
                TrashJournalRevision("same-operation", 9),
                TrashJournalRevision("same-operation", 9),
            ),
        )
    }
}
