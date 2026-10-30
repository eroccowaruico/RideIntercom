import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { token, room, offer, makeRuntime } from './support/runtime.mjs';

test('join needs no display name', async () => {
    const runtime = await makeRuntime();
    try {
        const response = await runtime.dispatchFetch(`https://worker.test/api/rooms/${room}/join`, {
            method: 'POST', headers: { Authorization: `Bearer ${token}` },
            body: JSON.stringify({ participantId: 'anonymous-rider', offer })
        });
        assert.equal(response.status, 200);
    } finally { await runtime.dispose(); }
});

test('extra display name is neither persisted nor broadcast to room peers', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-signaling-privacy-'));
    const runtime = await makeRuntime({}, { storageDirectory });
    try {
        const base = `https://worker.test/api/rooms/${room}`;
        const headers = { Authorization: `Bearer ${token}` };
        const response = await runtime.dispatchFetch(base + '/join', {
            method: 'POST', headers,
            body: JSON.stringify({ participantId: 'opaque-peer', displayName: 'PrivateHumanName', offer })
        });
        assert.equal(response.status, 200);
        const { sessionId } = await response.json();
        assert.equal((await runtime.dispatchFetch(`${base}/sessions/${sessionId}/publish`, {
            method: 'POST', headers, body: '{}'
        })).status, 200);
        const files = await readdir(storageDirectory, { recursive: true });
        const roomFiles = files.filter(path => path.includes('SignalingRoom') && /\.sqlite(?:-wal)?$/.test(path));
        assert.ok(roomFiles.length > 0, 'Room storage must exist');
        // Include SQLite's WAL so uncheckpointed values cannot escape the check.
        const bytes = Buffer.concat(await Promise.all(roomFiles.map(path => readFile(join(storageDirectory, path)))));
        assert.ok(bytes.includes(Buffer.from('opaque-peer')), 'The persisted member must be inspected');
        assert.ok(!bytes.includes(Buffer.from('displayName')));
        assert.ok(!bytes.includes(Buffer.from('PrivateHumanName')));
        const socketResponse = await runtime.dispatchFetch(`${base}/sessions/${sessionId}/signal`, {
            headers: { ...headers, Upgrade: 'websocket' }
        });
        assert.equal(socketResponse.status, 101);
        const ws = socketResponse.webSocket;
        try {
            const next = new Promise((resolve, reject) => {
                const timer = setTimeout(() => reject(new Error('No peer list')), 3000);
                ws.addEventListener('message', event => { clearTimeout(timer); resolve(JSON.parse(event.data)); }, { once: true });
            });
            ws.accept();
            assert.deepEqual(await next, { type: 'peers', peers: [{ id: 'opaque-peer', sessionId }] });
        } finally { ws.close(); }
    } finally {
        await runtime.dispose();
        await rm(storageDirectory, { recursive: true, force: true });
    }
});
