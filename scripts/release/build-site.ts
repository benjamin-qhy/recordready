import {resolve} from 'node:path';
import {buildSite} from './site-builder';
const version=buildSite(resolve(import.meta.dir,'../../site'));
console.log(`Built bilingual download site for ${version}`);
