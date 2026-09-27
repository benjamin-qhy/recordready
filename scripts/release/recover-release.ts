import {createPublicKey,verify,randomUUID} from 'node:crypto';
import {existsSync,mkdirSync,readFileSync,writeFileSync,renameSync,rmSync,lstatSync} from 'node:fs';
import {homedir} from 'node:os';
import {join,resolve} from 'node:path';
import {assertCatalog,assertNewRelease,assertRelease,generateAppcast,releaseVersionPattern,verifyArtifact,type DownloadRelease} from './release-model';

/** Repairs either interrupted metadata step; immutable release files are only read. */
export function recoverRelease(input:{site:string;version:string;publicKey:string}) {
 const {site,version,publicKey}=input;
 if(!releaseVersionPattern.test(version)) throw new Error('INVALID_RELEASE_VERSION');
 const lock=join(site,'.release.lock');mkdirSync(lock);
 const temporary:string[]=[];
 try {
  const folder=join(site,'releases',version);
  if(lstatSync(folder).isSymbolicLink()) throw new Error('RELEASE_SYMLINK_REFUSED');
  const release:DownloadRelease=JSON.parse(readFileSync(join(folder,'release.json'),'utf8'));assertRelease(release);
  if(release.version!==version) throw new Error('RELEASE_DIRECTORY_MISMATCH');
  const catalogFile=join(site,'releases.json'),feed=join(site,'updates/macos/arm64/appcast.xml');
  const releases:DownloadRelease[]=JSON.parse(readFileSync(catalogFile,'utf8')).releases;assertCatalog(releases);
  const existing=releases.find(r=>r.version===version);
  if(existing){
   if(releases[0]!==existing || JSON.stringify(existing)!==JSON.stringify(release)) throw new Error('RECOVERY_WOULD_REPLACE_EXISTING_RELEASE');
  }else assertNewRelease(version,release.build,releases);
  if(existsSync(feed)){
   const builds=[...readFileSync(feed,'utf8').matchAll(/<sparkle:version>(\d+)<\/sparkle:version>/g)].map(m=>Number(m[1]));
   if(builds.some(build=>build>release.build)) throw new Error('RECOVERY_WOULD_DOWNGRADE_FEED');
  }
  const rawKey=Buffer.from(publicKey.trim(),'base64');
  if(rawKey.length!==32) throw new Error('INVALID_PUBLIC_KEY');
  const key=createPublicKey({key:Buffer.concat([Buffer.from('302a300506032b6570032100','hex'),rawKey]),format:'der',type:'spki'});
  for(const artifact of [release.dmg,release.zip,...(release.deltas??[])]){
   const path=join(folder,artifact.name);
   if(lstatSync(path).isSymbolicLink()) throw new Error('ARTIFACT_SYMLINK_REFUSED');
   const bytes=readFileSync(path);verifyArtifact(bytes,artifact);
   const signature=artifact===release.zip?release.signature:('signature' in artifact?String(artifact.signature):undefined);
   if(signature && !verify(null,bytes,key,Buffer.from(signature,'base64'))) throw new Error('RECOVERY_SIGNATURE_INVALID');
  }
  const next=existing?releases:[release,...releases];assertCatalog(next);
  // Both complete files are staged before the first rename. Retrying this command repairs
  // interruption between atomic renames; catalog and feed cannot contain partial bytes.
  mkdirSync(join(site,'updates/macos/arm64'),{recursive:true});
  const id=randomUUID(),catalogNext=`${catalogFile}.${id}.next`,feedNext=`${feed}.${id}.next`;
  temporary.push(catalogNext,feedNext);
  writeFileSync(catalogNext,JSON.stringify({releases:next},null,2)+'\n',{flag:'wx'});
  writeFileSync(feedNext,generateAppcast(release),{flag:'wx'});
  renameSync(catalogNext,catalogFile);renameSync(feedNext,feed);
  return release;
 }finally{for(const path of temporary)rmSync(path,{force:true});rmSync(lock,{recursive:true});}
}
if(import.meta.main){
 const version=process.argv[2];if(!version)throw new Error('Usage: bun scripts/release/recover-release.ts <version>');
 const release=recoverRelease({site:resolve(import.meta.dir,'../../site'),version,publicKey:readFileSync(join(homedir(),'.recordready-release/keys/update.pub'),'utf8')});
 console.log(`Recovered metadata for verified ${release.version} (${release.build}); artifact bytes unchanged. Rebuild the site before publishing.`);
}
