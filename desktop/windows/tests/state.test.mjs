import {test} from 'node:test';import assert from 'node:assert/strict';
import {defaults,validateConfig,isBusy,elapsed,outputSize,fitRegion,sessionName} from '../state.mjs';
const display={id:1,bounds:{x:0,y:0,width:1536,height:864}},base=defaults('D:/RecordReady',1);
test('all capture and save transitions block installation',()=>{for(const phase of ['preparing','countdown','starting','recording','paused','saving'])assert.equal(isBusy({phase}),true);for(const phase of ['idle','ready','saved','failed','partial'])assert.equal(isBusy({phase}),false)});
test('invalid dimensions and vanished devices never silently change configuration',()=>{for(const patch of [{width:241},{height:0},{height:NaN},{quality:999},{displayID:'gone'},{microphone:'true'},{directory:''}])assert.throws(()=>validateConfig(base,patch,[display]));assert.equal(base.width,1080)});
test('paused wall clock time is excluded and final pause freezes clock',()=>{assert.equal(elapsed({started:1000,pausedAt:7000,pausedMs:2000},9000),4);assert.equal(elapsed({started:1000,pausedAt:0,pausedMs:2000},10000),7)});
test('output dimensions preserve aspect ratio and encoder even dimensions',()=>{assert.deepEqual(outputSize({...base,width:1920,height:1080}),[1920,1080]);assert.deepEqual(outputSize({...base,quality:2160}),[2160,3840]);const b=fitRegion(display,1080,1920);assert(b.x>=0&&b.y>=0&&b.x+b.width<=1536&&b.y+b.height<=864)});
test('each recording receives a unique directory',()=>assert.notEqual(sessionName(),sessionName()));
