import {createHash} from 'node:crypto';
import {createReadStream} from 'node:fs';
import {stat} from 'node:fs/promises';
export async function verifyInstaller(path,info){if((await stat(path)).size!==info.size)throw Error('installer_size_mismatch');const hash=createHash('sha512');for await(const chunk of createReadStream(path))hash.update(chunk);if(hash.digest('base64')!==info.sha512)throw Error('installer_hash_mismatch');}
