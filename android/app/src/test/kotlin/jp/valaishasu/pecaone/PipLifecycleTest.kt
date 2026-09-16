package jp.valaishasu.pecaone

import org.junit.Assert.*
import org.junit.Test

class PipLifecycleTest {
    private fun playingInPip() = PipLifecycle().apply {
        onStart()
        onResume()
        onPause()
        onPipChanged(true)
    }

    @Test fun expandingBeforeResumeDoesNotRequestAStop() {
        val state = playingInPip()
        state.onPipChanged(false)
        // No onStop: the Activity remains visible throughout the expansion,
        // even when onResume is delayed beyond the former 500 ms timeout.
        assertFalse(state.shouldStop(0, locked = false, interactive = true))
        state.onResume()
        assertNull(state.onStop()) // Subsequent ordinary backgrounding isn't PiP dismissal.
    }

    @Test fun restartingActivityCancelsCloseBeforeResumeArrives() {
        val state = playingInPip()
        val check = state.onStop()!!
        state.onPipChanged(false)
        state.onStart()
        assertFalse(state.shouldStop(check, locked = false, interactive = true))
        state.onResume()
    }

    @Test fun resumeBeforeModeChangeAlsoRestoresPlayback() {
        val state = playingInPip()
        state.onResume()
        state.onPipChanged(false)
        state.onPause()
        assertNull(state.onStop())
    }

    @Test fun closingWithModeChangeBeforeStopStillStops() {
        val state = playingInPip()
        state.onPipChanged(false)
        val check = state.onStop()!!
        assertTrue(state.shouldStop(check, locked = false, interactive = true))
    }

    @Test fun closingWithoutModeChangeStillStops() {
        val state = playingInPip()
        val check = state.onStop()!!
        assertTrue(state.shouldStop(check, locked = false, interactive = true))
    }

    @Test fun lockingAndUnlockingKeepTheSameSession() {
        val state = playingInPip()
        val check = state.onStop()!!
        assertFalse(state.shouldStop(check, locked = true, interactive = true))
        assertFalse(state.shouldStop(check, locked = false, interactive = false))
        state.onStart()
        assertFalse(state.shouldStop(check, locked = false, interactive = true))
    }

    @Test fun previousCloseCannotStopANewPlaybackSession() {
        val state = playingInPip()
        val check = state.onStop()!!
        state.resetSession()
        assertFalse(state.shouldStop(check, locked = false, interactive = true))
    }
}
