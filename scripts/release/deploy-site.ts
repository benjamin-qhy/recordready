import {execFileSync} from 'node:child_process';
import {createHash,randomUUID} from 'node:crypto';
import {readFileSync,readdirSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {homedir} from 'node:os';
import {assertCatalog,generateAppcast,verifyArtifact} from './release-model';
const repo=resolve(import.meta.dir,'../..'),site=join(repo,'site'),dist=join(site,'.dist');
const catalogBytes=readFileSync(join(site,'releases.json'));
const catalog=JSON.parse(catalogBytes.toString());assertCatalog(catalog.releases);
if(!catalog.releases.length) throw new Error('BUILD_RELEASE_FIRST');
const sha=(bytes:Uint8Array)=>createHash('sha256').update(bytes).digest('hex');
if(JSON.parse(readFileSync(join(dist,'site-build.json'),'utf8')).catalogSha256!==sha(catalogBytes)) throw new Error('REBUILD_SITE_FOR_CURRENT_CATALOG');
if(readFileSync(join(dist,'releases.json'),'utf8')!==catalogBytes.toString() || readFileSync(join(dist,'updates/macos/arm64/appcast.xml'),'utf8')!==generateAppcast(catalog.releases[0])) throw new Error('SITE_CATALOG_MISMATCH');
for(const release of catalog.releases){
 if(JSON.stringify(JSON.parse(readFileSync(join(site,'releases',release.version,'release.json'),'utf8')))!==JSON.stringify(release)) throw new Error('RELEASE_MANIFEST_CHANGED');
 for(const artifact of [release.dmg,release.zip,...(release.deltas??[])]) verifyArtifact(readFileSync(join(site,'releases',release.version,artifact.name)),artifact);
}
const files:Record<string,{bytes:number;sha256:string}>={};
const inventory=(root:string,prefix:string)=>{
 for(const entry of readdirSync(root,{withFileTypes:true})){
  const path=join(root,entry.name),key=`${prefix}/${entry.name}`;
  if(entry.isSymbolicLink()) throw new Error('UNEXPECTED_LOCAL_SYMLINK');
  if(entry.isDirectory()) inventory(path,key);
  else if(entry.isFile()){const bytes=readFileSync(path);files[key]={bytes:bytes.length,sha256:sha(bytes)};}
 }
};
inventory(dist,'web');for(const release of catalog.releases) inventory(join(site,'releases',release.version),`releases/${release.version}`);
const remote=process.env.RECORDREADY_SSH_TARGET ?? 'root@39.96.16.242',base='/srv/recordready',id=randomUUID();
if(!/^[a-z_][a-z0-9_-]*@39\.96\.16\.242$/.test(remote)) throw new Error('SSH_TARGET_MUST_USE_APPROVED_SERVER');
const identity=process.env.RECORDREADY_SSH_IDENTITY ?? join(homedir(),'.ssh/id_ed25519');
const control=process.env.RECORDREADY_SSH_CONTROL_PATH;
const sshArgs=[...(control?['-S',control]:['-i',identity]),'-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=15'];
const ssh=(command:string,input?:string)=>execFileSync('ssh',[...sshArgs,remote,command],{input,stdio:input?['pipe','inherit','inherit']:'inherit'});
const quote=(value:string)=>`'${value.replaceAll("'","'\\''")}'`;
const transport=['ssh',...sshArgs].map(quote).join(' ');
const sync=(source:string,target:string)=>execFileSync('rsync',['-rt','--partial','-e',transport,source,`${remote}:${target}`],{stdio:'inherit'});
// Failure to acquire the lock never releases a different publisher's lock.
ssh(`mkdir -p ${base} && mkdir ${base}/deploy.lock`);
try{
 ssh(`mkdir -p ${base}/staging/${id}/releases ${base}/staging/${id}/web`);
 for(const release of catalog.releases) sync(join(site,'releases',release.version),`${base}/staging/${id}/releases/`);
 sync(dist+'/',`${base}/staging/${id}/web/`);
 // Script is sent directly through stdin; payload is data, never interpolated into shell code.
 const script=readFileSync(join(import.meta.dir,'deploy-remote.py'),'utf8');
 const payload=Buffer.from(JSON.stringify({id,files})).toString('base64');
 const wrapper=script.replace("payload = json.load(sys.stdin)",`import base64\n    payload = json.loads(base64.b64decode('${payload}'))`);
 ssh('python3 -',wrapper);
}finally{ssh(`rmdir ${base}/deploy.lock`);}
console.log('Published. Verify HTTPS feed, page and downloaded artifact hashes before announcing.');
