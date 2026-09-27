import {copyFileSync,existsSync,mkdirSync,mkdtempSync,readFileSync,writeFileSync,renameSync,rmSync,symlinkSync,lstatSync} from 'node:fs';
import {createHash,randomUUID} from 'node:crypto';
import {basename,join} from 'node:path';
import {assertCatalog,generateAppcast} from './release-model';
import {renderPage} from './site-render';
export function buildSite(site:string){
 const lock=join(site,'.release.lock');mkdirSync(lock);
 let stage:string|undefined,legacy:string|undefined,pointer:string|undefined;
 const dist=join(site,'.dist');
 try{
  const bytes=readFileSync(join(site,'releases.json'));
  const catalog=JSON.parse(bytes.toString());assertCatalog(catalog.releases);
  if(!catalog.releases.length)throw new Error('BUILD_RELEASE_FIRST');
  stage=mkdtempSync(join(site,'.site-build-'));
  mkdirSync(join(stage,'updates/macos/arm64'),{recursive:true});
  writeFileSync(join(stage,'index.html'),renderPage(catalog.releases[0]));
  writeFileSync(join(stage,'download.html'),renderPage(catalog.releases[0]));
  copyFileSync(join(site,'style.css'),join(stage,'style.css'));
  writeFileSync(join(stage,'releases.json'),bytes);
  writeFileSync(join(stage,'updates/macos/arm64/appcast.xml'),generateAppcast(catalog.releases[0]));
  writeFileSync(join(stage,'site-build.json'),JSON.stringify({catalogSha256:createHash('sha256').update(bytes).digest('hex')})+'\n');
  if(!readFileSync(join(site,'releases.json')).equals(bytes))throw new Error('CATALOG_CHANGED_DURING_SITE_BUILD');
  pointer=join(site,`.site-next-${randomUUID()}`);symlinkSync(basename(stage),pointer,'dir');
  // One-time migration from the old physical .dist directory; keep its bytes for recovery.
  if(existsSync(dist)&&!lstatSync(dist).isSymbolicLink()){legacy=join(site,`.site-legacy-${randomUUID()}`);renameSync(dist,legacy);}
  try{renameSync(pointer,dist);}catch(error){if(legacy)renameSync(legacy,dist);throw error;}
  stage=undefined;pointer=undefined;
  return catalog.releases[0].version;
 }finally{
  if(stage)rmSync(stage,{recursive:true,force:true});if(pointer)rmSync(pointer,{force:true});
  rmSync(lock,{recursive:true});
 }
}
