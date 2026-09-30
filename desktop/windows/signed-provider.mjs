import {Provider} from 'electron-updater/out/providers/Provider.js';
import {verifyRelease,validateFeed,installerName} from './update-manifest.mjs';
export function signedProvider(config){
 validateFeed(config.feedUrl,config.validation===true);
 return class SignedProvider extends Provider{
  constructor(_options,_updater,runtime){super({...runtime,isUseMultipleRangeRequest:false});}
  async getLatestVersion(){const raw=await this.httpRequest(new URL(config.feedUrl),{'Cache-Control':'no-cache'});if(!raw)throw Error('empty_update_manifest');const r=verifyRelease(raw,config.publicKey);return {version:r.version,releaseDate:r.releaseDate,files:[{url:r.file.name,size:r.file.size,sha512:r.file.sha512}],path:r.file.name,sha512:r.file.sha512};}
  resolveFiles(update){return update.files.map(f=>({url:new URL(f.url,config.feedUrl),info:f}));}
  getBlockMapFiles(_url,oldVersion,newVersion){return [oldVersion,newVersion].map(v=>new URL(installerName(v)+'.blockmap',config.feedUrl));}
 };
}
