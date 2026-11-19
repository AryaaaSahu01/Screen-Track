export const FAST_INTERVAL_MS = 1000
export const SCREENSHOT_INTERVAL_MS = 30_000
export const FAST_OUTPUT_FPS = 30
export const SCREENSHOT_HOLD_US = 500_000

export type RecordingMode = 'fast' | 'screenshots' | 'both'

export type SampleKind = 'fast' | 'screenshot'

export type SampleRequest = Readonly <{
    kind: SampleKind
    slot: number
    scheduledActiveMs: number
    observedActiveMs: number
    missedSlots: number
}>

export type PresentationTiming = Readonly<{
    timestampUs: number
    durationUs: number
}>

function validateMilliseconds(value: number): void {
    if (!Number.isFinite(value) || value < 0 || value> Number.MAX_SAFE_INTEGER) {
        throw new RangeError('Time must be finite, non-negative milliseconds.')
    }
}

export class SamplePlan {
    private readonly kinds: readonly SampleKind[]
    private readonly lastSlot: Record<SampleKind, number> = { fast: -1, screenshot: -1 }
    private lastActiveMs = 0

    constructor(mode: RecordingMode) {
        if (!['fast', 'screenshots', 'both'].includes(mode)) {
            throw new TypeError('Choose fast, screenshots or both.')
        }
        this.kinds = mode === 'both' ? ['fast', 'screenshot'] :
            mode === 'fast' ? ['fast'] : ['screenshot']
    }

    takeDue(activeMs: number): readonly SampleRequest[] {
        validateMilliseconds(activeMs)
        if (activeMs < this.lastActiveMs) {
            throw new RangeError('Active time cannot move backwards.')
        }

        const requests: SampleRequest[] = []
        for (const kind of this.kinds) {
            const interval = kind === 'fast' ? FAST_INTERVAL_MS : SCREENSHOT_INTERVAL_MS
            const slot = activeMs === 0 ? 0 : Math.ceil(activeMs / interval) - 1
            const previous = this.lastSlot[kind]
            if (slot <= previous) continue

            requests.push(Object.freeze({
                kind,
                slot,
                scheduledActiveMs: slot * interval,
                observedActiveMs: activeMs,
                missedSlots: slot - previous -1,
            }))
            this.lastSlot[kind] = slot
        }
        this.lastActiveMs = activeMs
        return Object.freeze(requests)
    }
}

export function presentationTiming(kind: SampleKind, acceptedIndex: number): PresentationTiming {
    if (kind !== 'fast' && kind !== 'screenshot') {
        throw new TypeError('Unknown sample kind.')
    }
    if (!Number.isSafeInteger(acceptedIndex) || acceptedIndex < 0 ) {
        throw new RangeError('Use the zero-based index of an actually accepted sample.')
    }

    const timestampUs = kind === 'fast' ?
        Math.round(acceptedIndex * 1_000_000 / FAST_OUTPUT_FPS) :
        acceptedIndex * SCREENSHOT_HOLD_US
    const endUs = kind === 'fast' ?
        Math.round((acceptedIndex + 1) * 1_000_000 / FAST_OUTPUT_FPS):
        (acceptedIndex + 1) * SCREENSHOT_HOLD_US
    
    if (!Number.isSafeInteger(timestampUs) || !Number.isSafeInteger(endUs)) {
        throw new RangeError('The output timestamp exceeds the supported range.')
    }
    return Object.freeze({ timestampUs, durationUs: endUs - timestampUs})
}

export function isBeforeRecordingEnd(observedActiveMs: number, endedActiveMs: number): boolean {
    validateMilliseconds(observedActiveMs)
    validateMilliseconds(endedActiveMs)
    return observedActiveMs < endedActiveMs
}