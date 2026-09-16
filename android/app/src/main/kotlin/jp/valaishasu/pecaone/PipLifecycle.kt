package jp.valaishasu.pecaone

/** A PiP mode exit is also emitted when expanding; only onStop can imply dismissal. */
internal class PipLifecycle {
    var inPip = false
        private set
    var resumed = false
        private set
    private var started = false
    private var pipSession = false
    private var generation = 0

    fun onStart() {
        started = true
        generation++ // Invalidate a dismissal check from before this return.
    }

    fun onResume() {
        resumed = true
        if (!inPip) pipSession = false
    }

    fun onPause() {
        resumed = false
    }

    fun onPipChanged(value: Boolean) {
        inPip = value
        if (value) pipSession = true
        else if (resumed) pipSession = false
    }

    fun onStop(): Int? {
        started = false
        // Retain the session across a mode-exit callback that precedes onStop.
        return if (pipSession) ++generation else null
    }

    fun shouldStop(ticket: Int, locked: Boolean, interactive: Boolean): Boolean =
        ticket == generation && pipSession && !started && !resumed && !locked && interactive

    fun resetSession() {
        generation++
        pipSession = false
    }
}
