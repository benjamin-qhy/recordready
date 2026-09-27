import {test,expect} from 'bun:test';
import {createHash,generateKeyPairSync,sign} from 'node:crypto';
import {mkdirSync,mkdtempSync,writeFileSync,readFileSync,existsSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {recoverRelease} from './recover-release';
import {buildSite} from './site-builder';
import {generateAppcast} from './release-model';
function fixture(){
 const site=mkdtempSync(join(tmpdir(),'recordready-recovery-'));
 const keys=generateKeyPairSync('ed25519'),publicKey=keys.publicKey.export({format:'der',type:'spki'}).subarray(-32).toString('base64');
 const version='0.1.0-beta.1',root=join(site,'releases',version);mkdirSync(root,{recursive:true});
 const artifact=(ext:string)=>{const bytes=Buffer.from(ext==='zip'?'zip fixture long enough for delta':'dmg fixture'),name=`RecordReady-${version}-macos-arm64.${ext}`;writeFileSync(join(root,name),bytes);return {name,url:`https://recordready.qiushui.me/releases/${version}/${name}`,bytes:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex')};};
 const dmg=artifact('dmg'),zip=artifact('zip');
 const release={version,build:10001,date:'2026-09-27T00:00:00Z',sourceCommit:'b'.repeat(40),workingTree:false,minMacOS:'13.0',signing:'ad-hoc' as const,notes:{'zh-CN':'恢复测试','en-US':'Recovery test'},dmg,zip,signature:sign(null,readFileSync(join(root,zip.name)),keys.privateKey).toString('base64'),deltas:[]};
 writeFileSync(join(root,'release.json'),JSON.stringify(release));writeFileSync(join(site,'releases.json'),JSON.stringify({releases:[]}));writeFileSync(join(site,'style.css'),'body{}');
 return {site,root,version,publicKey,release,clean:()=>rmSync(site,{recursive:true,force:true})};
}
test('recovery restores stranded manifest catalog/feed without touching artifact bytes and can resume after catalog promotion',()=>{
 const f=fixture();try{const before=readFileSync(join(f.root,f.release.zip.name));recoverRelease(f);expect(JSON.parse(readFileSync(join(f.site,'releases.json'),'utf8')).releases).toEqual([f.release]);expect(readFileSync(join(f.site,'updates/macos/arm64/appcast.xml'),'utf8')).toBe(generateAppcast(f.release));expect(readFileSync(join(f.root,f.release.zip.name))).toEqual(before);rmSync(join(f.site,'updates/macos/arm64/appcast.xml'));recoverRelease(f);expect(existsSync(join(f.site,'updates/macos/arm64/appcast.xml'))).toBe(true);}finally{f.clean();}
});
test('recovery rejects artifact corruption, wrong signature, newer catalog and held lock before writing metadata',()=>{
 for(const kind of ['bytes','signature','newer','lock']){const f=fixture();try{
 if(kind==='bytes')writeFileSync(join(f.root,f.release.zip.name),'bad');
 if(kind==='signature'){f.release.signature='A'.repeat(86)+'==';writeFileSync(join(f.root,'release.json'),JSON.stringify(f.release));}
 if(kind==='newer')writeFileSync(join(f.site,'releases.json'),JSON.stringify({releases:[{...f.release,build:10002}]}));
 if(kind==='lock')mkdirSync(join(f.site,'.release.lock'));
 const before=readFileSync(join(f.site,'releases.json'));expect(()=>recoverRelease(f)).toThrow();expect(readFileSync(join(f.site,'releases.json'))).toEqual(before);expect(existsSync(join(f.site,'updates/macos/arm64/appcast.xml'))).toBe(false);
 }finally{f.clean();}}
});
test('site build replaces stale output with complete fresh snapshot and preserves prior site on failure',()=>{
 const f=fixture();try{writeFileSync(join(f.site,'releases.json'),JSON.stringify({releases:[f.release]}));mkdirSync(join(f.site,'.dist'));writeFileSync(join(f.site,'.dist/stale.html'),'stale');buildSite(f.site);expect(existsSync(join(f.site,'.dist/index.html'))).toBe(true);expect(existsSync(join(f.site,'.dist/stale.html'))).toBe(false);const html=readFileSync(join(f.site,'.dist/index.html'));rmSync(join(f.site,'style.css'));expect(()=>buildSite(f.site)).toThrow();expect(readFileSync(join(f.site,'.dist/index.html'))).toEqual(html);}finally{f.clean();}
});
