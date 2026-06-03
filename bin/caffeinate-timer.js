#!/usr/bin/env node
'use strict';

const { spawnSync } = require('child_process');
const { chmodSync, existsSync } = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const platform = process.platform;

let cmd, args, script;

if (platform === 'darwin') {
  script = path.join(root, 'caffeinate-timer.command');
  cmd = 'bash';
  args = [script];
} else if (platform === 'linux') {
  script = path.join(root, 'caffeinate-timer-universal.sh');
  cmd = 'bash';
  args = [script];
} else if (platform === 'win32') {
  script = path.join(root, 'caffeinate-timer-windows.bat');
  cmd = 'cmd.exe';
  args = ['/c', script];
} else {
  process.stderr.write('Unsupported platform: ' + platform + '\n');
  process.exit(1);
}

// Ensure execute permission on Unix (npm does not always preserve it)
if (platform !== 'win32' && existsSync(script)) {
  try { chmodSync(script, 0o755); } catch (_) {}
}

const result = spawnSync(cmd, args, { stdio: 'inherit' });

// Re-raise the signal so the shell sees the correct exit status
if (result.signal) {
  process.kill(process.pid, result.signal);
}
process.exit(result.status != null ? result.status : 1);
