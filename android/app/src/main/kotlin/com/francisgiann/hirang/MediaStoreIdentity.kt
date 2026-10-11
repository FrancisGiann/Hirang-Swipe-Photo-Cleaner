package com.francisgiann.hirang

/** Pure identity rules shared by the MediaStore adapter and JVM smoke checks. */
internal object MediaStoreIdentity {
    const val MATCH_EXCLUDE = 2
    const val MATCH_ONLY = 3

    data class QueryPlan(
        val matchTrashed: Int,
        val selection: String,
        val selectionArgs: List<String>,
    )

    fun queryPlan(id: Long, trashed: Boolean): QueryPlan = QueryPlan(
        matchTrashed = if (trashed) MATCH_ONLY else MATCH_EXCLUDE,
        selection = "_id = ? AND is_trashed = ?",
        selectionArgs = listOf(id.toString(), if (trashed) "1" else "0"),
    )

    fun matchesBeforeMutation(expected: Map<String, Any?>, observed: Map<String, Any?>): Boolean =
        matchesStableIdentity(expected, observed) && sameNumeric(expected, observed, "generationModified")

    fun matchesAfterTrash(expected: Map<String, Any?>, observed: Map<String, Any?>): Boolean =
        matchesStableIdentity(expected, observed)

    private fun matchesStableIdentity(expected: Map<String, Any?>, observed: Map<String, Any?>): Boolean {
        val required = listOf("volumeName", "volumeVersion", "mediaId", "generationAdded")
        if (required.any { expected[it] == null || observed[it] == null }) return false
        val fields = required + listOf("title", "dateTakenMillis", "sizeBytes", "album", "relativePath")
        return fields.all { key ->
            val expectedValue = expected[key]
            expectedValue == null || equalValue(key, expectedValue, observed[key])
        }
    }

    private fun sameNumeric(expected: Map<String, Any?>, observed: Map<String, Any?>, key: String): Boolean {
        val value = expected[key] ?: return true
        return numeric(value) != null && numeric(value) == numeric(observed[key])
    }

    private fun equalValue(key: String, left: Any, right: Any?): Boolean {
        if (right == null) return false
        return if (key in numericFields) numeric(left) != null && numeric(left) == numeric(right) else left == right
    }

    private fun numeric(value: Any?): Long? = (value as? Number)?.toLong()

    private val numericFields = setOf("mediaId", "generationAdded", "generationModified", "dateTakenMillis", "sizeBytes")
}
