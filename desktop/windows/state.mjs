import { randomUUID } from 'node:crypto';
export const busyPhases = new Set(['preparing','countdown','starting','recording','paused','saving']);
export const isBusy = state => busyPhases.has(state.phase);
export function validateConfig(current, patch, displays) {
  const next = {...current, ...patch};
  for (const key of ['width','height']) if (!Number.isInteger(next[key]) || next[key] < 240 || next[key] > 3840 || next[key] % 2) throw Error('invalid_size');
  if (![720,1080,1440,2160].includes(next.quality)) throw Error('invalid_quality');
  if (!displays.some(d=>String(d.id)===next.displayID)) throw Error('missing_display');
  if (typeof next.directory !== 'string' || !next.directory) throw Error('invalid_directory');
  for (const key of ['camera','microphone','mirror']) if(typeof next[key] !== 'boolean') throw Error('invalid_configuration');
  for (const key of ['cameraID','microphoneID']) if(typeof next[key] !== 'string') throw Error('invalid_device');
  return next;
}
export function outputSize({width,height,quality}) {
  const scale=({720:1280,1080:1920,1440:2560,2160:3840}[quality])/Math.max(width,height);
  return [Math.round(width*scale/2)*2,Math.round(height*scale/2)*2];
}
export function fitRegion(display, width, height) {
  const b=display.bounds, scale=Math.min((b.width-40)/width,(b.height-130)/height,1);
  return {x:Math.round(b.x+(b.width-width*scale)/2),y:Math.round(b.y+30),width:Math.round(width*scale),height:Math.round(height*scale)};
}
export function elapsed(state, now=Date.now()) {
  return state.started ? Math.max(0,((state.pausedAt || now)-state.started-state.pausedMs)/1000) : 0;
}
export function sessionName() {return `Session-${new Date().toISOString().replaceAll(':','-')}-${randomUUID().slice(0,8)}`;}
export function defaults(directory, displayID) {
  return {width:1080,height:1920,quality:1080,camera:false,microphone:false,cameraID:'',microphoneID:'',displayID:String(displayID),directory,
    mirror:false,previewShape:'square',previewLayout:'small',previewPosition:'bottom-right',text:'',fontSize:32,promptSpeed:24,promptOpacity:1,language:'zh-CN',theme:'light'};
}
