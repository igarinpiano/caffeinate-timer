// bin/caffeinate-timer.js がプラットフォームごとに何を spawn するかを調べる。
//
// process.platform を差し替え、spawn と chmodSync を差し替えたうえで
// ランチャーを require し、spawn の引数を JSON で1行出力する。
// PROBE_PLATFORM に win32 / darwin / linux / その他を指定して使う。
'use strict';

const { EventEmitter } = require('events');
const cp = require('child_process');
const fs = require('fs');

Object.defineProperty(process, 'platform', {
  value: process.env.PROBE_PLATFORM,
  configurable: true,
});

// 実ファイルの権限を変えないように差し替える
fs.chmodSync = () => {};

cp.spawn = (cmd, args, opts) => {
  process.stdout.write(JSON.stringify({ cmd, args, opts }) + '\n');
  const child = new EventEmitter();
  child.kill = () => {};
  return child;
};

// 未サポート環境では process.exit(1) が呼ばれる。終了コードで判別する。
require('../../bin/caffeinate-timer.js');
