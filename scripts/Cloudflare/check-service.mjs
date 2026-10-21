#!/usr/bin/env node
import { readFileSync } from 'node:fs';
// Read the credential from a private file, never from a command-line token argument.
try {
    if (!process.argv[2]) throw new Error('Usage: node scripts/Cloudflare/check-service.mjs <private-device.json>');
    const { workerURL, accessToken } = JSON.parse(readFileSync(process.argv[2], 'utf8'));
    const origin = new URL(workerURL);
    if (origin.protocol !== 'https:' || origin.username || origin.password || origin.pathname !== '/' || origin.search || origin.hash) throw new Error('Invalid HTTPS origin');
    for (const path of ['/health', '/api/status']) {
        const response = await fetch(new URL(path, origin), { redirect: 'error', signal: AbortSignal.timeout(15000),
            headers: path === '/health' ? {} : { Authorization: `Bearer ${accessToken}` } });
        if (!response.ok) throw new Error(`${path}: HTTP ${response.status}`);
        const data = await response.json();
        console.log(path === '/health' ? { service: data.service, protocol: data.protocol } : {
            month: data.month, reservedParticipantSeconds: data.reservedParticipantSeconds,
            monthlyParticipantSeconds: data.monthlyParticipantSeconds, activeSessions: data.activeSessions });
    }
    console.log('HTTP configuration verified. This does not verify SFU media or audio quality.');
} catch (error) { console.error(error.message); process.exitCode = 1; }
