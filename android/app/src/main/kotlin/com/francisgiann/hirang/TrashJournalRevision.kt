package com.francisgiann.hirang

/** Compare-and-set identity for one durable native trash-journal snapshot. */
internal data class TrashJournalRevision(val operationId: String?, val revision: Long)

internal object TrashJournalRevisionGuard {
    fun canCommit(expected: TrashJournalRevision, current: TrashJournalRevision): Boolean =
        expected == current
}
