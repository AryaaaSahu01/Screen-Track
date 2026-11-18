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