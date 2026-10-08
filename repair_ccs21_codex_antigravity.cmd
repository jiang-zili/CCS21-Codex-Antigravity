@echo off
setlocal
chcp 65001 >nul
set "CCS21_REPAIR_FILE=%~f0"
set "CCS21_REPAIR_MODE=%~1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:CCS21_REPAIR_FILE,[Text.Encoding]::UTF8);$m=':__POWERSHELL__';$i=$s.LastIndexOf($m);if($i -lt 0){throw 'Embedded repair missing'};& ([scriptblock]::Create($s.Substring($i+$m.Length))) $env:CCS21_REPAIR_MODE"
set "CCS21_REPAIR_RC=%errorlevel%"
if not "%~1"=="--check" pause
exit /b %CCS21_REPAIR_RC%
:__POWERSHELL__
$asarSource = @'
'use strict';
// Electron treats .asar as a virtual directory unless this is disabled.
process.noAsar = true;
// Bounded ASAR compatibility repair. No project or user-profile changes.
// Default: inspect. Apply requires an existing byte-identical backup and SHA-256.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const vm = require('vm');
const ENTRY = 'lib/frontend/packages_plugin-ext_lib_hosted_browser_hosted-plugin_js.js';
const OLD = '            show: webview.show\n        };';
const NEW = '        show:webview.show.bind(webview)};';
function check(condition, message) { if (!condition) throw new Error(message); }
function sha(buffer) { return crypto.createHash('sha256').update(buffer).digest('hex'); }
function exactRead(fd, size, position) {
    const out = Buffer.alloc(size); let used = 0;
    while (used < size) { const n = fs.readSync(fd, out, used, size - used, position + used); check(n > 0, 'Unexpected end of ASAR'); used += n; }
    return out;
}
function readEntry(archive) {
    const fd = fs.openSync(archive, 'r');
    try {
        const prefix = exactRead(fd, 16, 0);
        const headerSize = prefix.readUInt32LE(4), jsonSize = prefix.readUInt32LE(12);
        check(prefix.readUInt32LE(0) === 4, 'Unexpected ASAR size-pickle layout');
        check(prefix.readUInt32LE(8) === headerSize - 4, 'Unexpected ASAR header-pickle layout');
        check(jsonSize > 0 && jsonSize <= headerSize - 8 && headerSize < 100 * 1024 * 1024, 'Invalid ASAR header lengths');
        const jsonBytes = exactRead(fd, jsonSize, 16);
        const header = JSON.parse(jsonBytes.toString('utf8'));
        let entry = header; for (const name of ENTRY.split('/')) { check(entry.files && entry.files[name], 'Target entry missing'); entry = entry.files[name]; }
        check(!entry.unpacked && !entry.link && !entry.files, 'Target must remain a packed regular file');
        check(Number.isSafeInteger(entry.size) && entry.size > 0 && /^\d+$/.test(entry.offset), 'Invalid target entry metadata');
        const entryPosition = 8 + headerSize + Number(entry.offset);
        check(entryPosition + entry.size <= fs.statSync(archive).size, 'Target exceeds ASAR size');
        const content = exactRead(fd, entry.size, entryPosition);
        return { header, entry, content, entryPosition, jsonBytes, jsonSize, headerSize };
    } finally { fs.closeSync(fd); }
}
function integrityOf(content, metadata) {
    check(metadata && metadata.algorithm === 'SHA256', 'SHA256 entry integrity is required');
    check(Number.isSafeInteger(metadata.blockSize) && metadata.blockSize > 0, 'Invalid integrity block size');
    const blocks = [];
    for (let p = 0; p < content.length; p += metadata.blockSize) blocks.push(sha(content.subarray(p, p + metadata.blockSize)));
    return { hash: sha(content), blocks };
}
function verifyEntry(info) {
    const actual = integrityOf(info.content, info.entry.integrity);
    check(actual.hash === info.entry.integrity.hash, 'Target integrity hash mismatch');
    check(JSON.stringify(actual.blocks) === JSON.stringify(info.entry.integrity.blocks), 'Target integrity block hashes mismatch');
    new vm.Script(info.content.toString('utf8'), { filename: ENTRY });
    const source = info.content.toString('utf8');
    const start = source.indexOf('    async createNewWebviewView(viewId) {');
    const finish = source.indexOf('    registerViewWelcome(viewWelcome)', start);
    check(start >= 0 && finish > start, 'Expected WebviewView factory boundaries not found');
    const factory = source.slice(start, finish);
    const oldCount = factory.split(OLD).length - 1;
    const newCount = factory.split(NEW).length - 1;
    check((oldCount === 1 && newCount === 0) || (oldCount === 0 && newCount === 1), 'Unexpected show binding state');
    check(Buffer.byteLength(JSON.stringify(info.header), 'utf8') === info.jsonSize, 'Re-serialized ASAR header byte length would change');
    return { actual, source, start, finish, state: oldCount ? 'original-unbound' : 'patched-bound', oldCount, newCount };
}
function fileSha(file) {
    return new Promise((resolve, reject) => {
        const hash = crypto.createHash('sha256'); const input = fs.createReadStream(file);
        input.on('data', chunk => hash.update(chunk)); input.on('error', reject); input.on('end', () => resolve(hash.digest('hex')));
    });
}
function writeAll(fd, bytes, position) {
    let used = 0; while (used < bytes.length) { const n = fs.writeSync(fd, bytes, used, bytes.length - used, position + used); check(n > 0, 'Incomplete ASAR write'); used += n; }
}
async function compareOnlyPermittedRanges(file, backup, info) {
    const a = fs.openSync(file, 'r'), b = fs.openSync(backup, 'r');
    try {
        const total = fs.statSync(file).size;
        check(total === fs.statSync(backup).size, 'ASAR file size changed');
        const allowed = [[16, 16 + info.jsonSize], [info.entryPosition, info.entryPosition + info.entry.size]];
        const block = 4 * 1024 * 1024; let changed = 0;
        for (let p = 0; p < total; p += block) {
            const size = Math.min(block, total - p), aa = exactRead(a, size, p), bb = exactRead(b, size, p);
            if (aa.equals(bb)) continue;
            for (let i = 0; i < size; i++) if (aa[i] !== bb[i]) {
                const at = p + i; check(allowed.some(([from, to]) => at >= from && at < to), 'Unexpected ASAR modification outside target/header'); changed++;
            }
        }
        return changed;
    } finally { fs.closeSync(a); fs.closeSync(b); }
}
async function main() {
    const args = process.argv.slice(2); let mode = 'inspect', archive, backup, expected;
    for (let i = 0; i < args.length; i++) {
        const arg = args[i];
        if (arg === '--inspect') mode = 'inspect';
        else if (arg === '--apply') mode = 'apply';
        else if (arg === '--backup') backup = args[++i];
        else if (arg === '--expected-sha256') expected = args[++i];
        else if (!arg.startsWith('--') && !archive) archive = arg;
        else throw new Error('Unknown or incomplete argument: ' + arg);
    }
    check(archive, 'Usage: node patch-ccs-webview-show.cjs [--inspect|--apply] app.asar [--backup existing-original.asar --expected-sha256 ORIGINAL_SHA256]');
    archive = path.resolve(archive); check(fs.statSync(archive).isFile(), 'Archive path is not a regular file');
    const info = readEntry(archive), validation = verifyEntry(info);
    check(Buffer.byteLength(OLD) === Buffer.byteLength(NEW), 'Patch replacement byte lengths differ');
    const archiveHash = await fileSha(archive);
    if (mode === 'inspect') {
        console.log(JSON.stringify({ mode, archive, archiveBytes: fs.statSync(archive).size, archiveSha256: archiveHash, entry: ENTRY, entryBytes: info.entry.size, entryPosition: info.entryPosition, headerJsonBytes: info.jsonSize, state: validation.state, syntax: 'PASS', integrity: 'PASS', serializedHeaderLength: 'PASS', originalPatternCount: validation.oldCount, patchedPatternCount: validation.newCount }, null, 2));
        return;
    }
    check(backup && expected && /^[a-fA-F0-9]{64}$/.test(expected), 'Apply requires --backup and --expected-sha256');
    backup = path.resolve(backup);
    check(backup.toLowerCase() !== archive.toLowerCase(), 'Backup must be a different path');
    check(fs.existsSync(backup) && fs.statSync(backup).isFile(), 'Backup file must already exist');
    check(fs.realpathSync(backup).toLowerCase() !== fs.realpathSync(archive).toLowerCase(), 'Backup must resolve to a distinct file');
    check(validation.state === 'original-unbound', 'Archive is already patched; no write performed');
    expected = expected.toLowerCase();
    check(archiveHash === expected, 'Current archive SHA256 differs from expected original');
    check(fs.statSync(backup).size === fs.statSync(archive).size, 'Backup size differs from current archive');
    const backupHash = await fileSha(backup); check(backupHash === expected, 'Backup SHA256 differs from expected original');
    const patchedSource = validation.source.slice(0, validation.start) + validation.source.slice(validation.start, validation.finish).replace(OLD, NEW) + validation.source.slice(validation.finish);
    const patched = Buffer.from(patchedSource, 'utf8'); check(patched.length === info.content.length, 'Patch changed entry length');
    new vm.Script(patchedSource, { filename: ENTRY });
    const nextIntegrity = integrityOf(patched, info.entry.integrity); info.entry.integrity.hash = nextIntegrity.hash; info.entry.integrity.blocks = nextIntegrity.blocks;
    const nextHeader = Buffer.from(JSON.stringify(info.header), 'utf8'); check(nextHeader.length === info.jsonBytes.length, 'Patch changed header JSON length');
    // The caller must have stopped CCS before applying. Existing backup enables recovery.
    const fd = fs.openSync(archive, 'r+');
    try {
        check(exactRead(fd, info.content.length, info.entryPosition).equals(info.content), 'Archive target changed since inspection');
        check(exactRead(fd, info.jsonSize, 16).equals(info.jsonBytes), 'Archive header changed since inspection');
        writeAll(fd, patched, info.entryPosition); writeAll(fd, nextHeader, 16); fs.fsyncSync(fd);
    } finally { fs.closeSync(fd); }
    const after = readEntry(archive), verified = verifyEntry(after); check(verified.state === 'patched-bound', 'Post-write binding verification failed');
    check(after.entryPosition === info.entryPosition && after.entry.size === info.entry.size && after.jsonSize === info.jsonSize && after.headerSize === info.headerSize, 'ASAR sizes or offsets changed');
    const changedBytes = await compareOnlyPermittedRanges(archive, backup, after);
    console.log(JSON.stringify({ mode, archive, backup, originalArchiveSha256: expected, patchedArchiveSha256: await fileSha(archive), entry: ENTRY, entryBytes: after.entry.size, entryPosition: after.entryPosition, headerJsonBytes: after.jsonSize, state: verified.state, syntax: 'PASS', integrity: 'PASS', sizesAndOffsets: 'PASS', onlyTargetAndHeaderChanged: 'PASS', changedBytes }, null, 2));
}
main().catch(error => { console.error('ERROR: ' + error.message); process.exitCode = 1; });

'@
$proxySource = @'
'use strict';

const http = require('node:http');

const MAX_MAIN_BYTES = 20 * 1024 * 1024;
const MAIN_ORIGIN_ANCHOR = 'function Buc(a,b=window.location.origin){if(!a||a==="null")return!1;if(a===b||';
function patchAgyMainSource(source, allowedOrigin) {
  const origin = validateTheiaOrigin(allowedOrigin);
  const count = source.split(MAIN_ORIGIN_ANCHOR).length - 1;
  if (count !== 1) throw new Error('AGY_MAIN_ANCHOR_COUNT=' + count);
  // Keep every original origin rule; add precisely the caller's Theia origin.
  return source.replace(MAIN_ORIGIN_ANCHOR,
    MAIN_ORIGIN_ANCHOR.replace('if(a===b||', 'if(a===' + JSON.stringify(origin) + '||a===b||'));
}
function isMainRequest(req) {
  return req.method === 'GET' && String(req.url || '').split('?')[0] === '/main.js';
}
function failMainResponse(res, upstreamRes, reason) {
  upstreamRes.destroy();
  console.error('[CCS adapter] Antigravity main.js compatibility rejected: ' + reason);
  if (!res.headersSent) {
    res.writeHead(502, { 'Content-Type': 'text/plain', 'Cache-Control': 'no-store' });
    res.end('The CCS adapter could not safely adapt Antigravity initialization.');
  } else res.destroy();
}
function adaptMainResponse(upstreamRes, res, origin, headers) {
  const encoding = String(headers['content-encoding'] || 'identity').toLowerCase();
  const length = headers['content-length'];
  if (upstreamRes.statusCode !== 200 ||
      !/^(?:application\/(?:x-)?javascript|text\/javascript)(?:\s*;|$)/i.test(String(headers['content-type'] || '')) ||
      encoding !== 'identity' ||
      (length !== undefined && (!/^\d+$/.test(String(length)) || Number(length) > MAX_MAIN_BYTES))) {
    failMainResponse(res, upstreamRes, 'AGY_MAIN_RESPONSE_METADATA'); return;
  }
  let bytes = 0, failed = false;
  const chunks = [];
  upstreamRes.on('data', chunk => {
    if (failed) return;
    bytes += chunk.length;
    if (bytes > MAX_MAIN_BYTES) { failed = true; failMainResponse(res, upstreamRes, 'AGY_MAIN_SIZE_LIMIT'); return; }
    chunks.push(chunk);
  });
  upstreamRes.once('error', () => {
    if (!failed) { failed = true; failMainResponse(res, upstreamRes, 'AGY_MAIN_UPSTREAM_ERROR'); }
  });
  upstreamRes.once('end', () => {
    if (failed) return;
    try {
      const body = Buffer.concat(chunks);
      const text = body.toString('utf8');
      if (!body.equals(Buffer.from(text, 'utf8'))) throw new Error('AGY_MAIN_UTF8');
      const patched = Buffer.from(patchAgyMainSource(text, origin), 'utf8');
      for (const key of ['content-length', 'content-encoding', 'transfer-encoding', 'etag', 'last-modified', 'content-md5', 'digest']) delete headers[key];
      headers['content-length'] = String(patched.length);
      headers['cache-control'] = 'no-store';
      headers.pragma = 'no-cache';
      headers.expires = '0';
      res.writeHead(200, headers);
      res.end(patched);
    } catch (error) {
      failed = true; failMainResponse(res, upstreamRes, String(error.message).replace(/[^A-Z0-9_=]/g, '').slice(0,80));
    }
  });
  res.once('close', () => { if (!res.writableFinished) upstreamRes.destroy(); });
}

function validateTheiaOrigin(value) {
  const url = new URL(value);
  if (url.protocol !== 'http:' || url.username || url.password ||
      !/^[a-z0-9-]+\.webview\.localhost$/i.test(url.hostname) ||
      !url.port || url.pathname !== '/' || url.search || url.hash) {
    throw new Error('Expected one exact local Theia webview origin.');
  }
  return url.origin;
}

// CCS's WebviewImpl substitutes its actual origin/view ID into this URI.
// Never use cspSource here: it can contain a wildcard for all webviews.
function getTheiaWebviewOrigin(webview, resourceUri) {
  const resourceUrl = new URL(webview.asWebviewUri(resourceUri).toString());
  return validateTheiaOrigin(resourceUrl.origin);
}

function addExactFrameAncestor(policy, origin) {
  if (typeof policy !== 'string') throw new Error('Invalid backend CSP.');
  let found = false;
  const result = policy.split(';').map(directive => {
    if (!/^\s*frame-ancestors(?:\s|$)/i.test(directive)) return directive;
    found = true;
    const sources = directive.trim().split(/\s+/).slice(1);
    if (sources.includes("'none'") || sources.length === 0) {
      throw new Error('Backend CSP explicitly prohibits framing.');
    }
    const additions = [origin, 'file:'].filter(source => !sources.includes(source));
    return additions.length ? directive + ' ' + additions.join(' ') : directive;
  }).join(';');
  if (!found) throw new Error('Backend HTML is missing frame-ancestors protection.');
  return result;
}

/**
 * Adapt one agy backend for one exact CCS/Theia webview origin.
 * The backend target is fixed; all HTTP bodies, CSRF/auth headers, and WebSocket
 * traffic pass through unchanged. HTML frame-ancestors receives the supplied
 * exact origin. The /main.js initialization guard also accepts only that exact
 * origin, with bounded UTF-8 processing and no caching. The proxy binds to loopback.
 */
async function createCcsEmbedProxy({ backendUrl, allowedOrigin }) {
  const backend = new URL(backendUrl);
  const origin = validateTheiaOrigin(allowedOrigin);
  if (backend.protocol !== 'http:' || backend.username || backend.password ||
      !['localhost', '127.0.0.1', '[::1]'].includes(backend.hostname) ||
      !backend.port || backend.pathname !== '/' || backend.search || backend.hash) {
    throw new Error('Expected a fixed HTTP loopback agy backend origin.');
  }

  const sockets = new Set();
  const upstreams = new Set();
  let closing = false;
  let closePromise;

  function requestOptions(req) {
    if (!req.url || !req.url.startsWith('/') || req.url.startsWith('//')) {
      throw new Error('Only relative backend paths are accepted.');
    }
    return {
      hostname: backend.hostname === '[::1]' ? '::1' : backend.hostname,
      port: Number(backend.port),
      method: req.method,
      path: req.url,
      headers: (() => {
        if (!isMainRequest(req)) return req.headers;
        const headers = { ...req.headers, 'accept-encoding': 'identity' };
        delete headers['if-none-match'];
        delete headers['if-modified-since'];
        return headers;
      })(),
      agent: false,
    };
  }

  function trackUpstream(upstream) {
    upstreams.add(upstream);
    upstream.once('close', () => upstreams.delete(upstream));
    return upstream;
  }

  const server = http.createServer((req, res) => {
    if (closing) { res.writeHead(503).end(); return; }
    let options;
    try { options = requestOptions(req); }
    catch { res.writeHead(400).end(); return; }
    const upstream = trackUpstream(http.request(options, upstreamRes => {
      const headers = { ...upstreamRes.headers };
      if (isMainRequest(req)) {
        adaptMainResponse(upstreamRes, res, origin, headers);
        return;
      }
      try {
        if (/^text\/html(?:\s*;|$)/i.test(String(headers['content-type'] || ''))) {
          const csp = headers['content-security-policy'];
          headers['content-security-policy'] = Array.isArray(csp)
            ? csp.map(policy => addExactFrameAncestor(policy, origin))
            : addExactFrameAncestor(csp, origin);
        }
      } catch {
        upstreamRes.destroy();
        res.writeHead(502, { 'Content-Type': 'text/plain' });
        res.end('The CCS adapter could not preserve the backend framing policy.');
        return;
      }
      res.writeHead(upstreamRes.statusCode || 502, headers);
      upstreamRes.pipe(res);
      res.once('close', () => upstreamRes.destroy());
    }));
    upstream.on('error', () => {
      if (!res.headersSent) res.writeHead(502).end();
      else res.destroy();
    });
    req.once('aborted', () => upstream.destroy());
    res.once('close', () => { if (!res.writableFinished) upstream.destroy(); });
    req.pipe(upstream);
  });

  server.on('connection', socket => {
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));
  });

  server.on('upgrade', (req, socket, head) => {
    if (closing || String(req.headers.upgrade).toLowerCase() !== 'websocket') {
      socket.destroy(); return;
    }
    let options;
    try { options = requestOptions(req); }
    catch { socket.destroy(); return; }
    const upstream = trackUpstream(http.request(options));
    upstream.on('upgrade', (upstreamRes, upstreamSocket, upstreamHead) => {
      sockets.add(upstreamSocket);
      upstreamSocket.once('close', () => sockets.delete(upstreamSocket));
      let response = `HTTP/${upstreamRes.httpVersion} ${upstreamRes.statusCode} ${upstreamRes.statusMessage}\r\n`;
      for (let i = 0; i < upstreamRes.rawHeaders.length; i += 2) {
        response += `${upstreamRes.rawHeaders[i]}: ${upstreamRes.rawHeaders[i + 1]}\r\n`;
      }
      socket.write(response + '\r\n');
      if (upstreamHead.length) socket.write(upstreamHead);
      if (head.length) upstreamSocket.write(head);
      socket.pipe(upstreamSocket).pipe(socket);
      socket.on('error', () => upstreamSocket.destroy());
      upstreamSocket.on('error', () => socket.destroy());
      socket.once('close', () => upstreamSocket.destroy());
      upstreamSocket.once('close', () => socket.destroy());
    });
    // Preserve rejection status and headers; never convert a rejected upgrade.
    upstream.on('response', upstreamRes => {
      let response = `HTTP/${upstreamRes.httpVersion} ${upstreamRes.statusCode} ${upstreamRes.statusMessage}\r\n`;
      for (let i = 0; i < upstreamRes.rawHeaders.length; i += 2) {
        response += `${upstreamRes.rawHeaders[i]}: ${upstreamRes.rawHeaders[i + 1]}\r\n`;
      }
      socket.write(response + '\r\n');
      upstreamRes.pipe(socket);
    });
    upstream.on('error', () => socket.destroy());
    socket.once('close', () => upstream.destroy());
    upstream.end();
  });

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      server.removeListener('error', reject);
      resolve();
    });
  });
  server.unref();

  return {
    url: `http://127.0.0.1:${server.address().port}`,
    allowedOrigin: origin,
    dispose() {
      if (closePromise) return closePromise;
      closing = true;
      closePromise = new Promise(resolve => {
        server.close(resolve);
        for (const upstream of upstreams) upstream.destroy();
        for (const socket of sockets) socket.destroy();
      });
      return closePromise;
    },
  };
}

const proxiesByContext = new WeakMap();

async function getProxyUrl(backendUrl, allowedOrigin, context) {
  if (!context || !Array.isArray(context.subscriptions)) {
    throw new Error('Expected the extension context for proxy lifetime management.');
  }
  const origin = validateTheiaOrigin(allowedOrigin);
  const backendOrigin = new URL(backendUrl).origin;
  let cache = proxiesByContext.get(context);
  if (!cache) {
    cache = new Map();
    proxiesByContext.set(context, cache);
  }
  const key = backendOrigin + ' ' + origin;
  let pending = cache.get(key);
  if (!pending) {
    pending = createCcsEmbedProxy({ backendUrl, allowedOrigin: origin }).then(proxy => {
      context.subscriptions.push({ dispose: () => { void proxy.dispose(); } });
      return proxy;
    }).catch(error => {
      cache.delete(key);
      throw error;
    });
    cache.set(key, pending);
  }
  return (await pending).url;
}

module.exports = { getProxyUrl, createCcsEmbedProxy, getTheiaWebviewOrigin, patchAgyMainSource };

'@
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Say([string]$message) { Write-Host ('[CCS21] ' + $message) }
function Need([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
function Sha([string]$path) {
    $stream = [IO.File]::OpenRead($path)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
    finally { $hasher.Dispose(); $stream.Dispose() }
}
function Embedded([string]$value, [string]$file) {
    [System.IO.File]::WriteAllText($file, $value, [System.Text.UTF8Encoding]::new($false))
}
function NodeRun([string]$script, [string[]]$arguments) {
    $old = [Environment]::GetEnvironmentVariable('ELECTRON_RUN_AS_NODE', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE', '1', 'Process')
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $script:ccsExe
        $psi.Arguments = (@($script) + $arguments | ForEach-Object { '"' + ($_.Replace('"','\"')) + '"' }) -join ' '
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $process = [Diagnostics.Process]::Start($psi)
        $output = $process.StandardOutput.ReadToEnd()
        $errors = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Embedded Node operation failed: $errors $output" }
        return $output.Trim()
    } finally { [Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE', $old, 'Process') }
}
function Get-Extension([string]$plugins, [string]$prefix, [string]$name) {
    $dirs = @(Get-ChildItem -LiteralPath $plugins -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$prefix*" -and (Test-Path -LiteralPath (Join-Path $_.FullName 'extension\package.json')) })
    Need ($dirs.Count -eq 1) "Expected exactly one active $name extension in $plugins; found $($dirs.Count). Stop before changes."
    return (Join-Path $dirs[0].FullName 'extension')
}
function Stop-CCS([string]$exe) {
    $all = @(Get-CimInstance Win32_Process -Filter "name='ccstudio.exe'" | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.Equals($exe, [StringComparison]::OrdinalIgnoreCase) })
    if ($all.Count -eq 0) { return $null }
    $main = @($all | Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '\s--type=|resources\\app\.asar|--node-ipc' } | Select-Object -First 1)
    $workspace = $null
    if ($main.Count -eq 1 -and $main[0].CommandLine -match '"([^"]+\.theia-workspace)"') { $workspace = $Matches[1] }
    Say 'Please save open CCS21 work. Closing its main window normally; CCS12 and VS Code are untouched.'
    foreach ($item in $main) {
        $p = Get-Process -Id $item.ProcessId -ErrorAction SilentlyContinue
        if ($p) { [void]$p.CloseMainWindow() }
    }
    for ($i=0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 2
        $remaining = @(Get-CimInstance Win32_Process -Filter "name='ccstudio.exe'" | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.Equals($exe, [StringComparison]::OrdinalIgnoreCase) })
        if ($remaining.Count -eq 0) { return $workspace }
    }
    throw 'CCS21 did not exit normally within 120 seconds. No forced termination or repair was performed. Save your work, close CCS21 manually, and rerun.'
}

$mode = if ($args.Count -gt 0) { $args[0] } else { '--repair' }
Need ($mode -in @('--repair','--check')) 'Supported options: --repair (default) or --check.'
$script:ccsExe = 'C:\ti\ccs2101\ccs\theia\ccstudio.exe'
if (-not (Test-Path -LiteralPath $script:ccsExe)) {
    $candidates = @(Get-CimInstance Win32_Process -Filter "name='ccstudio.exe'" | Where-Object { $_.ExecutablePath -and $_.ExecutablePath -match '\\ccs21[^\\]*\\ccs\\theia\\ccstudio\.exe$' } | Select-Object -ExpandProperty ExecutablePath -Unique)
    Need ($candidates.Count -eq 1) 'Cannot identify one CCS21 installation. Install location is not the tested C:\ti\ccs2101 path.'
    $script:ccsExe = $candidates[0]
}
$asar = Join-Path (Split-Path $script:ccsExe) 'resources\app.asar'
Need (Test-Path -LiteralPath $asar) 'CCS21 app.asar is missing.'
$nodeVersion = NodeRun '-e' @('console.log(process.versions.node)')
Say "CCS21 bundled Node: $nodeVersion"

$profileBase = Join-Path $env:LOCALAPPDATA 'Texas Instruments\CCS\ccs2101'
$profiles = @(Get-ChildItem -LiteralPath $profileBase -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'theia\deployedPlugins')) })
Need ($profiles.Count -gt 0) 'No CCS21 user profile with deployed plugins was found.'
$active = @()
$ccsChildren = @(Get-CimInstance Win32_Process -Filter "name='ccstudio.exe'" | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.Equals($script:ccsExe, [StringComparison]::OrdinalIgnoreCase) -and $_.CommandLine -match '--user-data-dir=' })
foreach ($p in $profiles) {
    $electron = Join-Path $p.FullName 'electron'
    foreach ($proc in $ccsChildren) { if ($proc.CommandLine.IndexOf($electron, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $active += $p; break } }
}
$active = @($active | Select-Object -Unique)
if ($active.Count -eq 1) { $profile = $active[0].FullName }
elseif ($profiles.Count -eq 1) { $profile = $profiles[0].FullName }
else {
    $ranked = @($profiles | ForEach-Object {
        $log = Get-Item -LiteralPath (Join-Path $_.FullName 'theia\ccs_theia.log') -ErrorAction SilentlyContinue
        [pscustomobject]@{ Path=$_.FullName; Seen=$(if($log){$log.LastWriteTimeUtc}else{[datetime]::MinValue}) }
    } | Sort-Object Seen -Descending)
    Need ($ranked.Count -gt 0 -and $ranked[0].Seen -gt [datetime]::MinValue -and ($ranked.Count -eq 1 -or $ranked[0].Seen -gt $ranked[1].Seen)) 'Multiple CCS21 profiles cannot be distinguished. Launch the intended CCS21 profile and rerun. No changes made.'
    $profile = $ranked[0].Path
    Say 'CCS21 is closed; selected its most recently used profile.'
}
$plugins = Join-Path $profile 'theia\deployedPlugins'
$codex = Get-Extension $plugins 'openai.chatgpt@' 'Codex'
$agy = Get-Extension $plugins 'google.google-antigravity@' 'Antigravity'
$codexMeta = Get-Content -LiteralPath (Join-Path $codex 'package.json') -Raw | ConvertFrom-Json
$agyMeta = Get-Content -LiteralPath (Join-Path $agy 'package.json') -Raw | ConvertFrom-Json
Need ($agyMeta.version -eq '1.6.0') 'The Antigravity adapter was verified only with extension 1.6.0. No changes made.'
$agyMain = Join-Path $agy 'extension.js'
$agyText = [IO.File]::ReadAllText($agyMain)
Need ($agyText.Contains("require('./ccs-embed-proxy.cjs')") -and $agyText.Contains('getProxyUrl(serverUrl, webviewOrigin, this.context)')) 'The CCS21-adapted Antigravity 1.6.0 VSIX is required. Install the repository VSIX first; no changes made.'
$proxy = Join-Path $agy 'ccs-embed-proxy.cjs'
$codexBin = Join-Path $codex 'bin\windows-x86_64'
$codexExe = Join-Path $codexBin 'codex.exe'
$vscodeExt = Join-Path $env:USERPROFILE ('.vscode\extensions\openai.chatgpt-' + $codexMeta.version + '-win32-x64')
$sourceBin = Join-Path $vscodeExt 'bin\windows-x86_64'
$needCodex = -not (Test-Path -LiteralPath $codexExe)
if ($needCodex) {
    Need (Test-Path -LiteralPath (Join-Path $sourceBin 'codex.exe')) "Codex Windows backend is missing. Install the official matching win32-x64 Codex $($codexMeta.version) in VS Code, then rerun. No changes made."
    $sourceMeta = Get-Content -LiteralPath (Join-Path $vscodeExt 'package.json') -Raw | ConvertFrom-Json
    Need ($sourceMeta.version -eq $codexMeta.version -and $sourceMeta.publisher -eq 'openai') 'Official VS Code Codex metadata does not match the CCS copy. No changes made.'
    Need ((Sha (Join-Path $vscodeExt 'package.json')) -eq (Sha (Join-Path $codex 'package.json'))) 'Codex manifests differ between CCS and VS Code. No changes made.'
}
$backupRoot = Join-Path $env:LOCALAPPDATA 'CCS21RepairBackups'
$runDir = Join-Path $backupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$temp = Join-Path $env:TEMP ('ccs21-repair-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
$wasRunning = $ccsChildren.Count -gt 0
$workspace = $null
try {
    $asarTool = Join-Path $temp 'patch-ccs-webview-show.cjs'
    $proxyTool = Join-Path $temp 'ccs-embed-proxy.cjs'
    Embedded $asarSource $asarTool
    Embedded $proxySource $proxyTool
    $null = NodeRun '--check' @($asarTool)
    $null = NodeRun '--check' @($proxyTool)
    $inspection = NodeRun $asarTool @('--inspect', $asar)
    $asarState = ($inspection | ConvertFrom-Json).state
    Need ($asarState -in @('original-unbound','patched-bound')) 'CCS21 Webview patch preflight failed.'
    Say "Profile: $profile"
    Say "ASAR binding: $asarState; Codex backend present: $(-not $needCodex)"
    if ($mode -eq '--check') { Say 'Read-only preflight passed. No files or processes changed.'; return }

    # Finish all compatibility checks before touching CCS or its user data.
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    $workspace = Stop-CCS $script:ccsExe
    $backupAsar = Join-Path $runDir 'app.asar.original'
    $backupProxy = Join-Path $runDir 'ccs-embed-proxy.original.cjs'
    if ($asarState -eq 'original-unbound') {
        Copy-Item -LiteralPath $asar -Destination $backupAsar -ErrorAction Stop
        Need ((Sha $asar) -eq (Sha $backupAsar)) 'ASAR backup verification failed. No patch performed.'
    }
    if (Test-Path -LiteralPath $proxy) {
        Copy-Item -LiteralPath $proxy -Destination $backupProxy -ErrorAction Stop
        Need ((Sha $proxy) -eq (Sha $backupProxy)) 'Antigravity proxy backup verification failed. No patch performed.'
    }
    if ($needCodex -and (Test-Path -LiteralPath $codexBin)) {
        Copy-Item -LiteralPath $codexBin -Destination (Join-Path $runDir 'codex-bin.original') -Recurse -ErrorAction Stop
    }
    if ($asarState -eq 'original-unbound') {
        $hash = Sha $asar
        $result = NodeRun $asarTool @('--apply', $asar, '--backup', $backupAsar, '--expected-sha256', $hash)
        Need (($result | ConvertFrom-Json).state -eq 'patched-bound') 'ASAR post-patch verification failed.'
        Say 'Theia Webview show binding repaired and checked.'
    }
    if ((-not (Test-Path -LiteralPath $proxy)) -or ((Sha $proxy) -ne (Sha $proxyTool))) {
        Copy-Item -LiteralPath $proxyTool -Destination $proxy -Force -ErrorAction Stop
        Need ((Sha $proxy) -eq (Sha $proxyTool)) 'Antigravity adapter copy failed verification.'
        Say 'Antigravity CSP and main.js origin adapter updated.'
    }
    if ($needCodex) {
        if (-not (Test-Path -LiteralPath $codexBin)) { New-Item -ItemType Directory -Path $codexBin -Force | Out-Null }
        Get-ChildItem -LiteralPath $sourceBin -Force | Copy-Item -Destination $codexBin -Recurse -Force -ErrorAction Stop
        Need ((Sha $codexExe) -eq (Sha (Join-Path $sourceBin 'codex.exe'))) 'Codex backend copy failed verification.'
        Say 'Matching official Codex Windows backend restored.'
    }
    $cacheBackup = Join-Path $runDir 'cache'
    New-Item -ItemType Directory -Path $cacheBackup -Force | Out-Null
    $cacheNames = @('Cache','Code Cache','GPUCache','DawnGraphiteCache','DawnWebGPUCache','Service Worker')
    foreach ($name in $cacheNames) {
        $path = Join-Path (Join-Path $profile 'electron') $name
        if (Test-Path -LiteralPath $path) { Move-Item -LiteralPath $path -Destination (Join-Path $cacheBackup $name) -ErrorAction Stop }
    }
    $localCache = Join-Path $profile 'theia\localization-cache'
    if (Test-Path -LiteralPath $localCache) { Move-Item -LiteralPath $localCache -Destination (Join-Path $cacheBackup 'localization-cache') -ErrorAction Stop }
    $report = Join-Path $runDir 'repair-result.txt'
    @(
        "Time: $(Get-Date -Format o)"
        "CCS: $script:ccsExe"
        "Profile: $profile"
        "ASAR: $asarState -> patched-bound"
        "Codex version: $($codexMeta.version)"
        "Codex exe: $(Test-Path -LiteralPath $codexExe)"
        "Antigravity version: $($agyMeta.version)"
        "Proxy SHA256: $(Sha $proxy)"
        "Backups: $runDir"
        'Caches moved into backup; no projects, workspaces, source, or CCS project configuration changed.'
    ) | Set-Content -LiteralPath $report -Encoding UTF8
    Say "Repair complete. Backup and report: $runDir"
    if ($workspace -and (Test-Path -LiteralPath $workspace)) {
        Start-Process -FilePath $script:ccsExe -ArgumentList ('"' + $workspace + '"')
    } else { Start-Process -FilePath $script:ccsExe }
    Say 'CCS21 restarted. Open the Codex and Antigravity panels to confirm both render and accept input.'
} catch {
    if ($wasRunning) {
        $stillRunning = @(Get-CimInstance Win32_Process -Filter "name='ccstudio.exe'" | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.Equals($script:ccsExe, [StringComparison]::OrdinalIgnoreCase) })
        if ($stillRunning.Count -eq 0) {
            try {
                if ($workspace -and (Test-Path -LiteralPath $workspace)) { Start-Process -FilePath $script:ccsExe -ArgumentList ('"' + $workspace + '"') }
                else { Start-Process -FilePath $script:ccsExe }
                Say 'Repair stopped with an error; CCS21 was restarted. Review the error and backup before retrying.'
            } catch { Say 'Repair stopped and CCS21 could not be restarted automatically. Please reopen it manually.' }
        }
    }
    throw
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
