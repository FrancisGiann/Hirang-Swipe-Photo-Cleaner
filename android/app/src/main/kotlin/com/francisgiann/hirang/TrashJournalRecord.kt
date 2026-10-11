package com.francisgiann.hirang

/** Validates decoded durable operation data without interpreting absence as corruption. */
internal object TrashJournalRecord {
    private val validStatuses = setOf(
        "prepared", "awaitingSystemApproval", "resultReceived", "needsContinue",
        "reconciling", "complete", "cancelled", "interrupted",
    )

    fun validate(record: Map<String, Any?>): Map<String, Any?> {
        val id = record["id"] as? String
        val status = record["status"] as? String
        if (id.isNullOrBlank() || id.length > 128 || (status == null || status !in validStatuses) ||
            record["items"] !is List<*> || record["outcomes"] !is Map<*, *>) {
            throw IllegalStateException("The saved system-trash record is invalid.")
        }
        if (record.containsKey("revision") && !isValidRevision(record["revision"])) {
            throw IllegalStateException("The saved system-trash record has an invalid revision.")
        }
        return record
    }

    private fun isValidRevision(value: Any?): Boolean = when (value) {
        is Byte -> value >= 0
        is Short -> value >= 0
        is Int -> value >= 0
        is Long -> value >= 0L
        is Float -> value.isFinite() && value >= 0f && value % 1f == 0f && value < Long.MAX_VALUE.toFloat()
        is Double -> value.isFinite() && value >= 0.0 && value % 1.0 == 0.0 && value < 9.223372036854776E18
        else -> false
    }
}
