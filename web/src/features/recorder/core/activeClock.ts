export type ClockState = 'idle' | 'running' | 'paused' | 'stopped'

export type ClockSnapshot = Readonly<{
    state: ClockState
    activeMs: number
}>

export class ActiveClock {
    private state: ClockState = 'idle'
    private accumulatedMs = 0
    private runningSinceMs = 0
    private lastNowMs = Number.NEGATIVE_INFINITY
    private readonly now: () => number

    constructor(now: () => number = () => performance.now()) {
        this.now = now
    }

    private readNow(): number {
        const value = this.now()
        if (!Number.isFinite(value) || value < 0 || value > Number.MAX_SAFE_INTEGER || value < this.lastNowMs) {
            throw new RangeError('The clock must return finite, monotonic milliseconds.')
        }

        this.lastNowMs = value
        return value
    }

    snapshot(): ClockSnapshot {
        const activeMs = this.accumulatedMs +
            (this.state === 'running' ? this.readNow() - this.runningSinceMs : 0)
        return this.freezeSnapshot(activeMs)
    }

    private freezeSnapshot(activeMs: number): ClockSnapshot {
        return Object.freeze({ state: this.state, activeMs })
    }

    start(): ClockSnapshot {
        if (this.state !== 'idle') throw new Error('Create a new clock for a new session.')
        this.runningSinceMs = this.readNow()
        this.state = 'running'
        return this.freezeSnapshot(this.accumulatedMs)
    }

    pause(): ClockSnapshot {
        if (this.state === 'paused') return this.snapshot()
        if (this.state !== 'running') throw new Error('Only a running clock can pause.')
        this.accumulatedMs += this.readNow() - this.runningSinceMs
        this.state = 'paused'
        return this.snapshot()
    }

    resume(): ClockSnapshot {
        if (this.state === 'running') return this.snapshot()
        if (this.state !== 'paused') throw new Error('Only a paused clock can resume.')
        this.runningSinceMs = this.readNow()
        this.state = 'running'
        return this.freezeSnapshot(this.accumulatedMs)
    }

    stop(): ClockSnapshot {
        if (this.state === 'stopped') return this.snapshot()
        if (this.state === 'idle') throw new Error('Start the clock before stopping it.')
        if (this.state === 'running') {
            this.accumulatedMs += this.readNow() - this.runningSinceMs
        }

        this.state = 'stopped'
        return this.snapshot()
    }
}
