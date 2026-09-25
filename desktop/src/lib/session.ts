export const presets = [
  [720,1280], [1080,1920], [1440,2560], [2160,3840],
  [1280,720], [1920,1080], [2560,1440], [3840,2160],
  [1080,1440], [1080,1350], [1080,1080], [1440,1080],
] as const
export type Phase = 'idle'|'preparing'|'ready'|'countdown'|'starting'|'recording'|'saving'|'saved'|'partial'|'failed'
export const isLocked = (phase: Phase) => ['preparing','countdown','starting','recording','saving'].includes(phase)
export function validSize(width: number, height: number) {
  return [width,height].every(n => Number.isInteger(n) && n >= 240 && n <= 3840 && n % 2 === 0)
}
export function clock(seconds: number) {
  const total = Math.max(0, Math.floor(Number.isFinite(seconds) ? seconds : 0))
  const part = (n: number) => String(n).padStart(2,'0')
  return (total >= 3600 ? `${part(Math.floor(total/3600))}:` : '') + `${part(Math.floor(total/60)%60)}:${part(total%60)}`
}
export interface Device { id: string; name: string }
export interface Snapshot {
  catalog?: { cameras: Device[]; microphones: Device[]; displays: Device[] };
  cameraID?: string; microphoneID?: string; displayID?: string;
  mirror?: boolean; previewLayout?: string; previewPosition?: string; promptStarted?: boolean;
  phase: Phase; error: string; remaining: number; elapsed: number;
  width: number; height: number; camera: boolean; microphone: boolean;
  playing: boolean; fontSize?: number; promptSpeed?: number; level?: number; directory: string; devices: {camera: string; microphone: string};
  result: { saveResults?: Record<string,string>; fatalError?: string; outputPixels?: number[]; cameraOutputPixels?: number[]; screen?: {lastVideoPTS?:number}; camera?: {lastVideoPTS?:number} }
}
export const initial: Snapshot = {phase:'idle', error:'', remaining:0, elapsed:0, width:1080,height:1920,camera:true,microphone:true,playing:false,directory:'',devices:{camera:'',microphone:''},result:{}}
