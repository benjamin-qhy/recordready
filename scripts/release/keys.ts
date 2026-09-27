import { generateKeyPairSync, createPrivateKey, createPublicKey } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

/** Keys are independent from other products and never passed as command-line values. */
export function releaseKeys() {
 const root = join(homedir(), '.recordready-release/keys');
 mkdirSync(root, {recursive:true,mode:0o700});
 if (statSync(root).mode & 0o077) throw new Error('RELEASE_KEY_DIRECTORY_PERMISSIONS_UNSAFE');
 const privateFile = join(root, 'update.key'), publicFile = join(root, 'update.pub');
 if (!existsSync(privateFile) && !existsSync(publicFile)) {
  const pair = generateKeyPairSync('ed25519');
  writeFileSync(privateFile, pair.privateKey.export({format:'der',type:'pkcs8'}).subarray(-32).toString('base64'), {mode:0o600,flag:'wx'});
  writeFileSync(publicFile, pair.publicKey.export({format:'der',type:'spki'}).subarray(-32).toString('base64'), {mode:0o600,flag:'wx'});
 }
 if (!existsSync(privateFile) || !existsSync(publicFile) || (statSync(privateFile).mode & 0o077)) throw new Error('RELEASE_KEY_MISSING_OR_PERMISSIONS_UNSAFE');
 const seed = Buffer.from(readFileSync(privateFile,'utf8').trim(),'base64');
 if (seed.length !== 32) throw new Error('RELEASE_KEY_INVALID');
 const key = createPrivateKey({key:Buffer.concat([Buffer.from('302e020100300506032b657004220420','hex'),seed]),format:'der',type:'pkcs8'});
 const publicKey = createPublicKey(key).export({format:'der',type:'spki'}).subarray(-32).toString('base64');
 if (readFileSync(publicFile,'utf8').trim() !== publicKey) throw new Error('RELEASE_KEY_PAIR_MISMATCH');
 return {privateFile,publicKey};
}
