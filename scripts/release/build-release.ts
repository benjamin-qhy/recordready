import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { assertCatalog, assertNewRelease, assertRelease, generateAppcast, siteOrigin, feedPath, type DownloadRelease } from './release-model';
import { releaseKeys } from './keys';
import { buildReleaseDeltas } from './delta-release';

const [version, buildString, notesFile] = process.argv.slice(2);
if (!version || !/^\d+$/.test(buildString ?? '') || !notesFile) throw new Error('Usage: bun scripts/release/build-release.ts <version> <build> <bilingual-notes.json>');
if (process.platform !== 'darwin' || process.arch !== 'arm64') throw new Error('RELEASE_REQUIRES_MACOS_ARM64');
const repo = resolve(import.meta.dir, '../..'), site = join(repo, 'site');
const run = (cmd:string,args:string[],cwd=repo) => execFileSync(cmd,args,{cwd,stdio:'inherit'});
const read = (cmd:string,args:string[]) => execFileSync(cmd,args,{cwd:repo,encoding:'utf8'}).trim();
const build = Number(buildString), finalRoot = join(site,'releases',version);
const catalogFile = join(site,'releases.json');
const releases: DownloadRelease[] = JSON.parse(readFileSync(catalogFile,'utf8')).releases;
assertCatalog(releases);assertNewRelease(version,build,releases);
if (existsSync(finalRoot)) throw new Error('IMMUTABLE_RELEASE_ALREADY_EXISTS');
const notes = JSON.parse(readFileSync(resolve(notesFile),'utf8'));
if (!notes['zh-CN']?.trim() || !notes['en-US']?.trim()) throw new Error('BILINGUAL_RELEASE_NOTES_REQUIRED');
// Exclusive local lock covers the build, catalog and feed transition.
const lock = join(site,'.release.lock');mkdirSync(lock);
let staging: string | undefined;
try {
 const {privateFile,publicKey} = releaseKeys();
 const sourceCommit = read('git',['rev-parse','HEAD']);
 const workingTree = read('git',['status','--porcelain','--untracked-files=all']).length > 0;
 run('bun',['scripts/release/prepare-sparkle.ts']);
 run('npm',['exec','--','tauri','build','--bundles','app','--config',JSON.stringify({version})],join(repo,'desktop'));
 const built = join(repo,'desktop/src-tauri/target/release/bundle/macos/RecordReady.app');
 if (!existsSync(built)) throw new Error('TAURI_APP_MISSING');
 const workRoot = join(homedir(),'.recordready-release/builds');mkdirSync(workRoot,{recursive:true,mode:0o700});
 const output = mkdtempSync(join(workRoot,`${version}-`));
 const app = join(output,'RecordReady.app');run('ditto',[built,app]);
 const framework = join(app,'Contents/Frameworks/Sparkle.framework');
 mkdirSync(join(app,'Contents/Frameworks'),{recursive:true});
 run('ditto',[join(repo,'desktop/vendor/sparkle/Sparkle.framework'),framework]);
 const plist = join(app,'Contents/Info.plist');
 const values: Record<string, string | boolean> = {
  CFBundleShortVersionString:version,CFBundleVersion:String(build),LSMinimumSystemVersion:'13.0',
  SUFeedURL:siteOrigin+feedPath,SUPublicEDKey:publicKey,SUEnableAutomaticChecks:false,
  SUAutomaticallyUpdate:false,SUAllowsAutomaticUpdates:false,SUEnableInstallerLauncherService:false,SUVerifyUpdateBeforeExtraction:true,
 };
 for (const [key,value] of Object.entries(values)) run('plutil',['-replace',key,typeof value==='boolean'?'-bool':'-string',String(value),plist]);
 const executable = read('plutil',['-extract','CFBundleExecutable','raw','-o','-',plist]);
 const binary = join(app,'Contents/MacOS',executable);
 if (read('lipo',['-archs',binary]) !== 'arm64') throw new Error('EXPECTED_ARM64_ONLY');
 const linked = read('otool',['-L',binary]);
 if (!linked.includes('@rpath/Sparkle.framework/') && !linked.includes('@executable_path/../Frameworks/Sparkle.framework/')) throw new Error('SPARKLE_NOT_LINKED');
 const loads = read('otool',['-l',binary]);
 if (!loads.includes('@executable_path/../Frameworks')) run('install_name_tool',['-add_rpath','@executable_path/../Frameworks',binary]);
 // Sign nested Mach-O binaries first, then bundles from the inside out. Never use --deep for signing.
 const bundles:string[]=[];
 const walk = (folder:string) => {
  for (const entry of readdirSync(folder,{withFileTypes:true})) {
   const path=join(folder,entry.name);if(entry.isSymbolicLink()) continue;
   if(entry.isDirectory()) {walk(path);if(/\.(app|xpc|framework)$/.test(entry.name)) bundles.push(path);}
   else if(entry.isFile() && read('file',['-b',path]).includes('Mach-O')) run('codesign',['--force','--sign','-','--timestamp=none',path]);
  }
 };
 walk(join(app,'Contents'));
 for(const bundle of bundles) run('codesign',['--force','--sign','-','--timestamp=none',bundle]);
 run('codesign',['--force','--sign','-','--timestamp=none',app]);
 run('codesign',['--verify','--deep','--strict',app]);
 mkdirSync(join(site,'releases'),{recursive:true});staging=mkdtempSync(join(site,'.staging-'));
 const zipName=`RecordReady-${version}-macos-arm64.zip`,dmgName=`RecordReady-${version}-macos-arm64.dmg`;
 run('ditto',['-c','-k','--sequesterRsrc','--keepParent',app,join(staging,zipName)]);
 const zipCheck=join(output,'zip-check');
 run('ditto',['-x','-k',join(staging,zipName),zipCheck]);
 run('codesign',['--verify','--deep','--strict',join(zipCheck,'RecordReady.app')]);
 if(read('plutil',['-extract','CFBundleVersion','raw','-o','-',join(zipCheck,'RecordReady.app/Contents/Info.plist')])!==String(build)) throw new Error('ZIP_VERSION_MISMATCH');
 const dmgSource=join(output,'dmg');mkdirSync(dmgSource);run('ditto',[app,join(dmgSource,'RecordReady.app')]);symlinkSync('/Applications',join(dmgSource,'Applications'));
 run('hdiutil',['create','-volname','RecordReady','-srcfolder',dmgSource,'-ov','-format','UDZO',join(staging,dmgName)]);
 run('hdiutil',['verify',join(staging,dmgName)]);
 const artifact=(name:string)=>{const bytes=readFileSync(join(staging!,name));return {name,bytes:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex'),url:`${siteOrigin}/releases/${version}/${name}`};};
 const signer=join(repo,'desktop/vendor/sparkle/bin/sign_update');
 const signature=read(signer,['--ed-key-file',privateFile,'-p',join(staging,zipName)]);
 run(signer,['--ed-key-file',privateFile,'--verify',join(staging,zipName),signature]);
 const release:DownloadRelease={version,build,date:new Date().toISOString(),sourceCommit,workingTree,minMacOS:'13.0',signing:'ad-hoc',notes,dmg:artifact(dmgName),zip:artifact(zipName),signature};
 release.deltas=buildReleaseDeltas({repo,release,previous:releases.slice(0,3),newApp:app,privateFile,releaseRoot:staging});
 assertRelease(release);
 writeFileSync(join(staging,'SHA256SUMS.txt'),[release.dmg,release.zip,...release.deltas].map(a=>`${a.sha256}  ${a.name}\n`).join(''));
 writeFileSync(join(staging,'release-notes.md'),`# RecordReady ${version}\n\n${notes['zh-CN']}\n\n${notes['en-US']}\n`);
 writeFileSync(join(staging,'release.json'),JSON.stringify(release,null,2)+'\n');
 // Recheck external mutation before promoting immutable bytes.
 if (readFileSync(catalogFile,'utf8') !== JSON.stringify({releases},null,2)+'\n') {
  const current=JSON.parse(readFileSync(catalogFile,'utf8')).releases;
  if (JSON.stringify(current)!==JSON.stringify(releases)) throw new Error('CATALOG_CHANGED_DURING_BUILD');
 }
 if(existsSync(finalRoot)) throw new Error('IMMUTABLE_RELEASE_ALREADY_EXISTS');
 renameSync(staging,finalRoot);staging=undefined;
 writeFileSync(catalogFile+'.next',JSON.stringify({releases:[release,...releases]},null,2)+'\n');renameSync(catalogFile+'.next',catalogFile);
 const feed=join(site,feedPath);mkdirSync(join(site,'updates/macos/arm64'),{recursive:true});
 writeFileSync(feed+'.next',generateAppcast(release));renameSync(feed+'.next',feed);
 console.log(`Prepared immutable ${version} (${build}); signed app retained at ${app}. No upload performed.`);
} finally {
 if(staging) rmSync(staging,{recursive:true,force:true});
 rmSync(lock,{recursive:true});
}
