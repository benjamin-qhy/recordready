import {createPublicKey,verify} from 'node:crypto';
export function installerName(version){if(!/^\d+\.\d+\.\d+(?:-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?$/.test(version))throw Error('invalid_version');return `RecordReady-${version}-x64.exe`;}
export function validateFeed(value,validation=false){const url=new URL(value);if(url.username||url.password||url.hash||url.search||(url.protocol!=='https:'&&!(validation&&url.protocol==='http:'&&url.hostname==='127.0.0.1')))throw Error('untrusted_update_source');return url;}
export function verifyRelease(raw,key){
 if(Buffer.byteLength(raw)>65536)throw Error('release_too_large');
 const envelope=JSON.parse(raw);
 if(typeof envelope.payload!=='string'||typeof envelope.signature!=='string'||! /^[A-Za-z0-9+/]+={0,2}$/.test(envelope.payload)||! /^[A-Za-z0-9+/]{86}==$/.test(envelope.signature)||! /^[A-Za-z0-9+/]{43}=$/.test(key))throw Error('invalid_update_signature');
 const payload=Buffer.from(envelope.payload,'base64'),publicKey=createPublicKey({format:'der',type:'spki',key:Buffer.concat([Buffer.from('302a300506032b6570032100','hex'),Buffer.from(key,'base64')])});
 if(!verify(null,payload,publicKey,Buffer.from(envelope.signature,'base64')))throw Error('invalid_update_signature');
 const r=JSON.parse(payload);
 if(r.schema!==1||r.platform!=='win32'||r.arch!=='x64'||r.file?.name!==installerName(r.version)||!Number.isSafeInteger(r.file.size)||r.file.size<=0||typeof r.file.sha512!=='string'||! /^[A-Za-z0-9+/]{86}==$/.test(r.file.sha512)||!Number.isFinite(Date.parse(r.releaseDate)))throw Error('invalid_update_manifest');
 return r;
}
