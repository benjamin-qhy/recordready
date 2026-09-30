import {open} from 'node:fs/promises';

// Validate container completion without loading a potentially large recording.
// Full codec decoding is part of release acceptance, not a UI-thread operation.
export async function validateMP4(path) {
  const file=await open(path,'r');
  try {
    const {size}=await file.stat();const seen=new Set();let offset=0;
    while(offset<size){
      const header=Buffer.alloc(16),{bytesRead}=await file.read(header,0,Math.min(16,size-offset),offset);
      if(bytesRead<8)throw Error('truncated_mp4');
      let length=header.readUInt32BE(0),headerSize=8;const type=header.toString('ascii',4,8);
      if(length===1){if(bytesRead<16)throw Error('truncated_mp4');length=Number(header.readBigUInt64BE(8));headerSize=16;}
      if(length===0)length=size-offset;
      if(!Number.isSafeInteger(length)||length<headerSize||offset+length>size)throw Error('truncated_mp4');
      if(length>headerSize)seen.add(type);
      offset+=length;
    }
    if(!['ftyp','moov','mdat'].every(type=>seen.has(type)))throw Error('incomplete_mp4');
  } finally {await file.close();}
}
