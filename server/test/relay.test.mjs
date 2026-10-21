import test from 'node:test';
import assert from 'node:assert/strict';
import { makeRuntime, provider, token, room } from './support/runtime.mjs';

test('SFU packet channels use no retransmission, authorize subscriptions and close allocations', async () => {
    const runtime = await makeRuntime();
    const offer = { type: 'offer', sdp: 'v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=mid:0\r\na=sctp-port:5000\r\n' };
    async function call(path, body, method = 'POST') {
        return runtime.dispatchFetch(`https://worker.test/api/rooms/${room}/${path}`, { method, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, ...(body ? { body: JSON.stringify(body) } : {}) });
    }
    try {
        provider.requests = [];
        const a = await call('join', { participantId: 'a', displayName: 'A', offer });
        assert.equal(a.status, 200);
        const alice = await a.json();
        const b = await call('join', { participantId: 'b', displayName: 'B', offer });
        assert.equal(b.status, 200);
        const bob = await b.json();
        assert.equal((await call(`sessions/${alice.sessionId}/publish`, {})).status, 200);
        assert.equal((await call(`sessions/${bob.sessionId}/publish`, {})).status, 200);
        const pulled = await call(`sessions/${bob.sessionId}/pull`, { peerIds: ['a'] });
        assert.equal(pulled.status, 200);
        assert.equal((await pulled.json()).channels[0].peerID, 'a');
        assert.equal((await call(`sessions/${bob.sessionId}/pull`, { peerIds: ['outsider'] })).status, 403);
        for (const request of provider.requests.filter(r => r.url.endsWith('/datachannels/new'))) {
            for (const channel of request.body.dataChannels.filter(c => c.dataChannelName === 'group-audio-v1')) {
                assert.equal(channel.ordered, false); assert.equal(channel.maxRetransmits, 0);
            }
        }
        assert.equal((await call(`sessions/${alice.sessionId}`, undefined, 'DELETE')).status, 200);
        assert(provider.requests.some(r => r.url.endsWith('/datachannels/close')));
    } finally { await runtime.dispose(); }
});
