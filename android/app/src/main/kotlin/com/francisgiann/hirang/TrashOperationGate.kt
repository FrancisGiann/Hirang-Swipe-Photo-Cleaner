package com.francisgiann.hirang

/** Synchronous reservation used to serialize native requests before any worker is dispatched. */
internal class TrashOperationGate {
    private var reservation: String? = null

    @Synchronized
    fun tryReserve(id: String): Boolean {
        if (id.isBlank() || reservation != null) return false
        reservation = id
        return true
    }

    @Synchronized
    fun restore(id: String) {
        if (id.isNotBlank() && reservation == null) reservation = id
    }

    @Synchronized
    fun current(): String? = reservation

    @Synchronized
    fun isReserved(id: String): Boolean = reservation == id

    @Synchronized
    fun release(id: String): Boolean {
        if (reservation != id) return false
        reservation = null
        return true
    }
}
