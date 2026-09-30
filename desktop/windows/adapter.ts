type Bridge = {invoke:<T>(command:string,args?:Record<string,unknown>)=>Promise<T>;on:(event:string,fn:(payload:unknown)=>void)=>()=>void}
declare global {interface Window {recordready?:Bridge}}
export const isTauri=()=>!!window.recordready
if(window.recordready)document.body.dataset.windows='true'
export function invoke<T>(command:string,args:Record<string,unknown>={}):Promise<T>{return window.recordready!.invoke<T>(command,args)}
export async function listen<T>(event:string,handler:(event:{payload:T})=>void){return window.recordready!.on(event,payload=>handler({payload:payload as T}))}
export function getCurrentWindow(){return {label:new URLSearchParams(location.search).get('view')??'main',scaleFactor:()=>invoke<number>('window-scale'),outerPosition:()=>invoke<{x:number;y:number}>('window-position'),startDragging:()=>Promise.resolve()}}
export async function open(_options:unknown){return invoke<string|null>('choose-directory')}
