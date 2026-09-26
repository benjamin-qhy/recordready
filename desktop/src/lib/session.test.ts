import { describe, expect, it } from 'vitest'
import { clock, isLocked, presets, validSize, deviceLabel, recordingControlsOnly } from './session'
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
    for (const phase of ['preparing','countdown','starting','recording','paused','saving'] as const) expect(isLocked(phase)).toBe(true)
    expect(isLocked('saved')).toBe(false)
    expect(recordingControlsOnly('recording')).toBe(true)
    expect(recordingControlsOnly('paused')).toBe(true)
    expect(recordingControlsOnly('countdown')).toBe(false)
  })
  it('formats long recordings without wrapping hours or displaying invalid time', () => {
    expect(clock(3599.9)).toBe('59:59'); expect(clock(3600)).toBe('01:00:00')
    expect(clock(NaN)).toBe('00:00'); expect(clock(-3)).toBe('00:00')
  })
  it('shows the selected or actual default device without silently substituting another', () => {
    const devices = [{id:'a',name:'Built-in'}, {id:'b',name:'USB mic'}]
    expect(deviceLabel(devices,'b','a','Default','Disconnected')).toBe('USB mic')
    expect(deviceLabel(devices,'','a','Default','Disconnected')).toBe('Built-in')
    expect(deviceLabel(devices,'missing','a','Default','Disconnected')).toBe('Disconnected')
    expect(deviceLabel(devices,'','','Default','Disconnected')).toBe('Default')
  })
})
