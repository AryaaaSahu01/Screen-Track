import assert from 'node:assert/strict'
import { test } from 'node:test'
import { ActiveClock } from '../src/features/recorder/core/activeClock.ts'
import {
    SamplePlan,
    presentationTiming,
    isBeforeRecordingEnd,
} from '../src/features/recorder/core/samplePlan.ts'

function fakeClock(initial = 0) {
    let time = initial
    return { clock: new ActiveClock(() => time), set: (value) => { time = value }}
}

test('unpaused time is measured from this monotonic clock', () => {
    const { clock, set } = fakeClock(100)
    assert.deepEqual(clock.snapshot(), { state: 'idle', activeMs: 0 })
    clock.start()
    set(1700)
    assert.equal(clock.snapshot().activeMs, 1600)
})

test('pause and resume exclude the full pause interval', () => {
    const { clock, set } = fakeClock()
    clock.start()
    set(1500)
    clock.pause()
    set(9000)
    assert.equal(clock.snapshot().activeMs, 1500)
    clock.resume()
    set(9500)
    assert.deepEqual(clock.stop(), { state: 'stopped', activeMs: 2000 })
})

test('repeated pause/resume/stop events cannot double-count time', () => {
    const { clock, set } = fakeClock()
    clock.start()
    set(100)
    clock.pause()
    set(500)
    clock.pause()
    clock.resume()
    clock.resume()
    set(600)
    assert.equal(clock.stop().activeMs, 200)
    set(100)
    assert.equal(clock.stop().activeMs, 200)
    assert.throws(() => clock.start())
})

test('invalid lifecycle transitions are rejected', () => {
    const { clock } = fakeClock()
    assert.throws(() => clock.pause())
    assert.throws(() => clock.resume())
    assert.throws(() => clock.stop())
})

test('backwards and non-finite clock reading are rejected', () => {
    const { clock, set } = fakeClock(100)
    clock.start()
    set(90)
    assert.throws(() => clock.snapshot(), RangeError)
    set(Number.NaN)
    assert.throws
    set(200)
    assert.equal(clock.pause().activeMs, 100)
})

test ('stopping during a pause does not add paused time', () =>{
    const { clock, set } = fakeClock()
    clock.start()
    set(300)
    clock.pause()
    set(20_000)
    assert.equal(clock.stop().activeMs, 300)
})

test('both mode has tow sample families under one schedule', () => {
    const plan = new SamplePlan('both')
    assert.deepEqual(plan.takeDue(0).map((s) => s.kind), ['fast', 'screenshot'])
    assert.equal(plan.takeDue(0).length, 0)
})

test('a one-minute end-exclusive interval has 60 ideal fast samples', () => {
    const plan = new SamplePlan('fast')
    let count = plan.takeDue(0).length
    for ( let second = 1; second < 60; second++ ) count += plan.takeDue(second * 1000 + 0.1).length
    assert.equal(count, 60)
    assert.equal(plan.takeDue(60_000).length, 0)
})

test('screenshots keep the cumulative active-time schedule across pauses', () => {
    const plan = new SamplePlan('screenshots')
    assert.equal(plan.takeDue(0).length, 1)
    assert.equal(plan.takeDue(20_000).length, 0)
    //real world time can advance, the active clock time for app remains as per the time it was turned on.
    assert.equal(plan.takeDue(20_000).length, 0)
    assert.equal(plan.takeDue(30_000).length, 0)
    assert.equal(plan.takeDue(30_001)[0].slot, 1)
})

test('a late poll requests one current sample and reports skipped slots', () => {
    const plan = new SamplePlan('fast')
    plan.takeDue(0)
    const due = plan.takeDue(10_001)
    assert.equal(due.length, 1)
    assert.equal(due[0].slot, 10)
    assert.equal(due[0].missedSlots, 9)
    assert.equal(due[0].observedActiveMs, 10_001)
})

test('invalid or backwards sample time cannot corrupt the schedule', () => {
    const plan = new SamplePlan('fast')
    plan.takeDue(1000)
    for (const invalid of [-1, Number.NaN, Number.POSITIVE_INFINITY, 999]) {
        assert.throws(() => plan.takeDue(invalid), RangeError)
    }
    assert.equal(plan.takeDue(1001)[0].slot, 1)
})

test('unknown recording modes are rejected at runtime', () => {
    assert.throws(() => new SamplePlan('other'), TypeError)
})

test('60 accepted fast frames produce exactly two seconds', () => {
    const last = presentationTiming('fast', 59)
    assert.equal(last.timestampsUs + last.durationUs, 2_00_000)
})

test('30fps integer-microsecond timestamps have no rounding gaps', () => {
    let end = 0
    for (let index = 0; index < 120; index++) {
        const sample = presentationTiming('fast', index)
        assert.equal(sample.timestampsUs, end)
        assert(sample.durationUs > 0)
        end += sample.durationUs
    }
    assert.equal(end, 4_000_000)
})

test('120 accepted screenshots at half-second holds produce one minute', () => {
    const last = presentationTiming('screenshot', 119)
    assert.equal(last.timestampsUs + last.durationUs, 60_000_000)
})

test('output timing uses accepeted indices and rejects unsafe numbers', () => {
    for (const valid of [-1, 0.5, Number.NaN, Number.MAX_SAFE_INTEGER]) {
        assert.throws(() => presentationTiming('fast', invalid), RangeError)
    }
    assert.throws(() => presentationTiming('other', 0), TypeError)
})

test('a sample exactly on Stop is outside the final recording', () => {
    assert.equal(isBeforeRecordingEnd(59_999, 60_000), true)
    assert.equal(isBeforeRecordingEnd(60_000, 60_000), false)
    assert.equal(isBeforeRecordingEnd(0,0), false)
})

test('returned snapshots and sample requests cannot be mutated',  () => {
    const { clock } = fakeClock()
    assert(Object.isFrozen(clock.start()))
    const request = new SamplePlan('fast').takeDue(0)
    assert(Object.isFrozen(request))
    assert(Object.isFrozen(request[0]))
    assert(Object.isFrozen(presentationTiming('fast', 0)))
})