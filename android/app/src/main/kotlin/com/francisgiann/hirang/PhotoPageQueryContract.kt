package com.francisgiann.hirang

/** Fixed native MediaStore query terms shared with the query contract tests. */
internal object PhotoPageQueryContract {
    fun sortOrder(mode: String): String = when (mode) {
        "largestKnown" -> "_size DESC, volume_name DESC, _id DESC"
        else -> "CASE WHEN datetaken > 0 THEN datetaken WHEN date_added > 0 THEN date_added * 1000 ELSE 0 END DESC, date_added DESC, volume_name DESC, _id DESC"
    }

    fun effectiveCaptureMillis(dateTaken: Long, dateAddedSeconds: Long): Long = when {
        dateTaken > 0L -> dateTaken
        dateAddedSeconds > 0L -> dateAddedSeconds * 1000L
        else -> 0L
    }

    fun hasDescendingBoundary(
        currentPrimary: Long,
        currentSecondary: Long,
        currentVolume: String,
        currentId: Long,
        previousPrimary: Long,
        previousSecondary: Long,
        previousVolume: String,
        previousId: Long,
    ): Boolean = when {
        currentPrimary > previousPrimary -> false
        currentPrimary < previousPrimary -> true
        currentSecondary > previousSecondary -> false
        currentSecondary < previousSecondary -> true
        currentVolume > previousVolume -> false
        currentVolume < previousVolume -> true
        else -> currentId < previousId
    }
}
