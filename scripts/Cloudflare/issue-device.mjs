#!/usr/bin/env node
import { randomBytes, createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync, chmodSync, renameSync, existsSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
export function issueDevice(endpoint, owner, directory) {
    const url = new URL(endpoint);
    if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash || url.pathname !== '/') throw new Error('Use an HTTPS service origin');
    if (!/^[a-zA-Z0-9_-]{1,64}$/.test(owner)) throw new Error('Owner must be an ASCII device name');
    mkdirSync(directory, { recursive: true, mode: 0o700 }); chmodSync(directory, 0o700);
    const registryPath = join(directory, 'client-tokens.json'), devicePath = join(directory, `${owner}.json`);
    if (existsSync(devicePath)) throw new Error('Device file already exists; revoke or choose another device name');
    const registry = existsSync(registryPath) ? JSON.parse(readFileSync(registryPath, 'utf8')) : {};
    if (Object.values(registry).includes(owner)) throw new Error('Device name already registered');
    const token = randomBytes(32).toString('base64url');
    registry[createHash('sha256').update(token).digest('hex')] = owner;
    // This manual registry is for the invited trial, not public user enrollment.
    if (Buffer.byteLength(JSON.stringify(registry)) > 4500) throw new Error('Trial registry full; use a public identity service before expanding');
    writeFileSync(devicePath, JSON.stringify({ workerURL: url.origin, accessToken: token }, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
    const temporary = registryPath + '.tmp';
    writeFileSync(temporary, JSON.stringify(registry, null, 2) + '\n', { mode: 0o600 });
    chmodSync(temporary, 0o600); renameSync(temporary, registryPath);
    return { devicePath, registryPath };
}
if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
    try {
        const [endpoint, owner, directory = 'server/.trial-credentials'] = process.argv.slice(2);
        if (!endpoint || !owner) throw new Error('Usage: node scripts/Cloudflare/issue-device.mjs https://service.example device-name [private-directory]');
        console.log(JSON.stringify(issueDevice(endpoint, owner, resolve(directory)), null, 2));
    } catch (error) { console.error(error.message); process.exitCode = 1; }
}
