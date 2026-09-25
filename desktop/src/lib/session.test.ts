import { describe, expect, it } from 'vitest'
import { clock, isLocked, presets, validSize } from './session'
describe('capture invariants', () => {
  it('accepts all twelve presets and even custom boundaries', () => {
    expect(presets).toHaveLength(12)
    presets.forEach(([w,h]) => expect(validSize(w,h)).toBe(true))
    expect(validSize(240,3840)).toBe(true)
  })
  it('rejects fractional, odd, empty-number and out-of-range sizes', () => {
    for (const n of [0,239,241,3842,1080.5,NaN,Infinity]) expect(validSize(n,1920)).toBe(false)
  })
  it('locks configuration throughout countdown, startup and finalization', () => {
    for (const phase of ['preparing','countdown','starting','recording','saving'] as const) expect(isLocked(phase)).toBe(true)
    expect(isLocked('saved')).toBe(false)
  })
  it('formats long recordings without wrapping hours or displaying invalid time', () => {
    expect(clock(3599.9)).toBe('59:59'); expect(clock(3600)).toBe('01:00:00')
    expect(clock(NaN)).toBe('00:00'); expect(clock(-3)).toBe('00:00')
  })
})
