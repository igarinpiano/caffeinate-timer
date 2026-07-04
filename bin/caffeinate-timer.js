#!/usr/bin/env node
'use strict';

const { spawn } = require('child_process');
const { chmodSync, existsSync } = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const platform = process.platform;

let cmd, args, script;
const spawnOpts = { stdio: 'inherit' };

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
  // Absolute path: a bare "cmd.exe" is resolved via the current directory
  // before PATH on Windows, allowing binary planting from the cwd.
  cmd = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'cmd.exe');
  // `cmd /c "<path>"` drops the quotes around the path as soon as it contains
  // one of & < > ( ) @ ^ | -- so an install under e.g. "C:\Program Files
  // (x86)\..." fails with "'C:\Program' is not recognized".  /s makes cmd strip
  // exactly one outer quote pair, so double-quoting the path keeps it intact.
  // /d skips any AutoRun command the machine has configured.
  args = ['/d', '/s', '/c', '""' + script + '""'];
  spawnOpts.windowsVerbatimArguments = true;
} else {
  process.stderr.write('Unsupported platform: ' + platform + '\n');
  process.exit(1);
}

// Ensure execute permission on Unix (npm does not always preserve it)
if (platform !== 'win32' && existsSync(script)) {
  try { chmodSync(script, 0o755); } catch (_) { }
}

const child = spawn(cmd, args, spawnOpts);

// Ctrl+C (SIGINT) is delivered to the entire process group, so the shell
// script receives it directly and runs its own trap handler.  Suppress the
// default Node.js exit here so stdin stays valid while the script finishes
// its interrupt handling.
process.on('SIGINT', () => { });

// Forward SIGTERM to the child so an external kill reaches the script.
process.on('SIGTERM', () => { child.kill('SIGTERM'); });

child.on('error', (err) => {
  process.stderr.write('Failed to start: ' + err.message + '\n');
  process.exit(1);
});

child.on('exit', (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
  }
  process.exit(code != null ? code : 1);
});
