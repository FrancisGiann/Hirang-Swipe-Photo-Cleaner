package com.francisgiann.hirang

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class TrashOperationGateTest {
    @Test fun twoCloselySpacedCallsReserveOnlyOneOperation() {
        val gate = TrashOperationGate()
        val start = CountDownLatch(1)
        val done = CountDownLatch(32)
        val accepted = AtomicInteger(0)
        val executor = Executors.newFixedThreadPool(8)
        repeat(32) { index ->
            executor.execute {
                start.await()
                if (gate.tryReserve("operation-$index")) accepted.incrementAndGet()
                done.countDown()
            }
        }
        start.countDown()
        assertTrue(done.await(2, TimeUnit.SECONDS))
        executor.shutdownNow()
        assertEquals(1, accepted.get())
    }

    @Test fun staleReleaseCannotUnlockNewOperation() {
        val gate = TrashOperationGate()
        assertTrue(gate.tryReserve("one"))
        assertTrue(gate.release("one"))
        assertTrue(gate.tryReserve("two"))
        assertFalse(gate.release("one"))
        assertEquals("two", gate.current())
    }

    @Test fun restoredPromptReservationKeepsOperationLocked() {
        val gate = TrashOperationGate()
        gate.restore("awaiting-android")
        assertTrue(gate.isReserved("awaiting-android"))
        assertFalse(gate.tryReserve("another"))
    }
}
