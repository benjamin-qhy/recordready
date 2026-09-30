const {contextBridge,ipcRenderer}=require('electron');
contextBridge.exposeInMainWorld('recordready',{
  platform:'win32',
  invoke:(command,args={})=>ipcRenderer.invoke('rr:invoke',command,args),
  on:(event,callback)=>{const allowed=['section','restore-focus','engine','config'];if(!allowed.includes(event))throw Error('invalid_event');const listener=(_e,data)=>callback(data);ipcRenderer.on('rr:'+event,listener);return()=>ipcRenderer.removeListener('rr:'+event,listener)},
  engineReply:(id,value,error)=>ipcRenderer.send('rr:engine-reply',{id,value,error}),
  chunk:(token,name,bytes)=>ipcRenderer.invoke('rr:chunk',token,name,bytes),
  report:(value)=>ipcRenderer.send('rr:report',value),
});
