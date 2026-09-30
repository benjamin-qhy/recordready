import {generateKeyPairSync,createPublicKey,sign,createHash} from 'node:crypto';
import {readFileSync,writeFileSync,mkdirSync,existsSync,statSync,copyFileSync} from 'node:fs';
import {homedir} from 'node:os';import {join,resolve,basename} from 'node:path';import {execFileSync} from 'node:child_process';import {createRequire} from 'node:module';
import {installerName,verifyRelease,validateFeed} from './update-manifest.mjs';
const require=createRequire(import.meta.url),builderRequire=createRequire(require.resolve('electron-builder'));
const {buildBlockMap}=builderRequire('app-builder-lib/out/targets/blockmap/blockmap.js');
const here=resolve(import.meta.dirname),keys=join(homedir(),'.recordready-release','windows-keys'),privatePath=join(keys,'update.pem'),publicPath=join(keys,'public.txt');
const [command,version,input]=process.argv.slice(2);
if(command==='init'){
 mkdirSync(keys,{recursive:true});const user=execFileSync('whoami',[],{encoding:'utf8'}).trim();execFileSync('icacls',[keys,'/inheritance:r','/grant:r',`${user}:(OI)(CI)F`],{stdio:'pipe'});
 if(existsSync(privatePath)!==existsSync(publicPath))throw Error('partial_key_pair_do_not_regenerate');
 if(!existsSync(privatePath)){const pair=generateKeyPairSync('ed25519');writeFileSync(privatePath,pair.privateKey.export({type:'pkcs8',format:'pem'}),{flag:'wx'});writeFileSync(publicPath,pair.publicKey.export({type:'spki',format:'der'}).subarray(-32).toString('base64'),{flag:'wx'});}
 const publicKey=readFileSync(publicPath,'utf8').trim();if(createPublicKey(readFileSync(privatePath)).export({type:'spki',format:'der'}).subarray(-32).toString('base64')!==publicKey)throw Error('key_pair_mismatch');
 mkdirSync(join(here,'resources'),{recursive:true});writeFileSync(join(here,'resources/update-config.json'),JSON.stringify({feedUrl:'https://recordready.qiushui.me/updates/windows/x64/release.json',publicKey}));console.log('Windows update key and embedded configuration ready; private key remains outside the repository.');
}else if(command==='sign'){
 const name=installerName(version),installer=resolve(input||join(here,'release',name));if(basename(installer)!==name)throw Error('installer_name_mismatch');const config=JSON.parse(readFileSync(join(here,'resources/update-config.json')));validateFeed(config.feedUrl);
 const key=readFileSync(privatePath);if(createPublicKey(key).export({type:'spki',format:'der'}).subarray(-32).toString('base64')!==config.publicKey)throw Error('key_pair_mismatch');
 const folder=join(here,'release/published',version);if(existsSync(folder))throw Error('immutable_release_already_exists');mkdirSync(folder,{recursive:true});const target=join(folder,name);copyFileSync(installer,target);
 const map=await buildBlockMap(target,'gzip',target+'.blockmap');const release={schema:1,platform:'win32',arch:'x64',version,releaseDate:new Date().toISOString(),file:{name,size:statSync(target).size,sha512:map.sha512}};const payload=Buffer.from(JSON.stringify(release));const envelope=JSON.stringify({payload:payload.toString('base64'),signature:sign(null,payload,key).toString('base64')})+'\n';verifyRelease(envelope,config.publicKey);writeFileSync(join(folder,'release.json'),envelope);
 const inventory={};for(const file of [name,name+'.blockmap','release.json']){const bytes=readFileSync(join(folder,file));inventory[file]={bytes:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex')};}
 writeFileSync(join(folder,'inventory.json'),JSON.stringify({version,sourceCommit:execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim(),workingTree:!!execFileSync('git',['status','--porcelain'],{encoding:'utf8'}).trim(),files:inventory},null,2));console.log(JSON.stringify({version,folder,files:inventory}));
}else throw Error('Usage: node release.mjs init | sign VERSION [INSTALLER]');
