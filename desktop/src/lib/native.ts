import { invoke, isTauri } from '@tauri-apps/api/core'
import { getCurrentWindow } from '@tauri-apps/api/window'
import type { Snapshot } from './session'
export const desktop = isTauri()
export async function native(action: string, args: Record<string,unknown> = {}): Promise<Snapshot> {
  if (!desktop) throw new Error('nativeRequired')
  return invoke('native_request', {request:{action,...args}})
}
export let returnFocus: HTMLElement | null = null
export async function menuAnchor(trigger: HTMLElement) {
  const window = getCurrentWindow()
  const scale = await window.scaleFactor(), origin = await window.outerPosition()
  const rect = trigger.getBoundingClientRect()
  return [origin.x / scale + rect.x, origin.y / scale + rect.y, rect.width, rect.height]
}
export async function section(name: string, trigger?: HTMLElement) {
  returnFocus = trigger ?? (document.activeElement instanceof HTMLElement ? document.activeElement : null)
  if (desktop) {
    const window = getCurrentWindow()
    localStorage.setItem('rr.settingsSource', window.label)
    const scale = await window.scaleFactor(), origin = await window.outerPosition()
    const rect = returnFocus?.getBoundingClientRect()
    const anchor = rect && rect.width > 0 ? [origin.x / scale + rect.x, origin.y / scale + rect.y, rect.width, rect.height] : null
    await invoke('show_settings', {section:name,anchor})
  }
  else window.location.search = `?view=settings&section=${name}`
}
