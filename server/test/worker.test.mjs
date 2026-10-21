import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { token, hash, room, offer, provider, makeRuntime } from './support/runtime.mjs';
let runtime;
before(async () => { runtime = await makeRuntime(); });
after(async () => { await runtime?.dispose(); });
const call = (path, body, method = 'POST', instance = runtime, credential = token) => instance.dispatchFetch(`https://worker.test${path}`, {
    method, headers: { Authorization: `Bearer ${credential}`, 'Content-Type': 'application/json' }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
const join = (id, target = room, instance = runtime) => call(`/api/rooms/${target}/join`, { participantId: id, displayName: id, offer }, 'POST', instance);

test('unauthenticated and malformed provider.requests never contact the provider', async () => {
    provider.requests = [];
    assert.equal((await runtime.dispatchFetch('https://worker.test/health')).status, 200);
    assert.equal((await call(`/api/rooms/${room}/join`, {}, 'POST', runtime, 'invalid')).status, 401);
    assert.equal((await call(`/api/rooms/${room}/join`, { participantId: 'x', offer: { ...offer, sdp: offer.sdp + 'm=video 9 RTP/AVP 96\r\n' } })).status, 400);
    assert.equal((await call('/api/rooms/guessable/join', {})).status, 400);
    assert.equal(provider.requests.length, 0);
});

test('SFU publishing, authorized subscription, renewal and cleanup use the real contract', async () => {
    const a = await (await join('a')).json(); const b = await (await join('b')).json();
    assert.ok(a.sessionId); assert.equal(a.sessionDescription.type, 'answer');
    assert.ok(a.expiresAt > Date.now()); assert.equal(a.renewAfterSeconds, 300);
    assert.equal('participantToken' in a, false); assert.equal('sfuEndpoint' in a, false);
    const base = `/api/rooms/${room}/sessions/${a.sessionId}`;
    const pull = await (await call(base + '/pull', { peerIds: ['b'] })).json();
    assert.equal(pull.sessionDescription.type, 'offer');
    assert.equal((await call(base + '/answer', { sessionDescription: { type: 'answer', sdp: offer.sdp } }, 'PUT')).status, 200);
    const before = provider.requests.length;
    const renewed = await (await call(base + '/renew', {})).json();
    assert.equal(renewed.sessionId, a.sessionId); assert.equal(provider.requests.length, before);
    assert.equal((await call(base + '/pull', { peerIds: ['not-in-room'] })).status, 403);
    assert.equal((await call(`/api/rooms/${'b'.repeat(64)}/sessions/${a.sessionId}/renew`, {})).status, 404);
    assert.equal((await call(base, undefined, 'DELETE')).status, 200);
    assert.equal((await call(`/api/rooms/${room}/sessions/${b.sessionId}`, undefined, 'DELETE')).status, 200);
    assert.ok(provider.requests.some(r => r.url.endsWith('/tracks/close') && r.body.force === true));
});

test('quota reservations survive concurrent provider.requests and prevent provider calls', async () => {
    const limited = await makeRuntime({ MONTHLY_PARTICIPANT_SECONDS: '600' });
    try {
        const results = await Promise.all([join('one', 'c'.repeat(64), limited), join('two', 'd'.repeat(64), limited)]);
        assert.deepEqual(results.map(r => r.status).sort(), [200, 429]);
        const status = await (await call('/api/status', undefined, 'GET', limited)).json();
        assert.equal(status.reservedParticipantSeconds, 600);
    } finally { await limited.dispose(); }
});

test('kill switch fails closed and upstream failure does not publish a participant', async () => {
    const disabled = await makeRuntime({ SERVICE_ENABLED: 'false' });
    try { assert.equal((await join('off', room, disabled)).status, 503); } finally { await disabled.dispose(); }
    provider.upstreamFails = true;
    try { assert.equal((await join('failed', 'e'.repeat(64))).status, 502); } finally { provider.upstreamFails = false; }
});

test('room capacity and duplicate membership are enforced', async () => {
    const small = await makeRuntime({ MAX_ROOM_PARTICIPANTS: '2' });
    try {
        assert.equal((await join('one', room, small)).status, 200);
        assert.equal((await join('one', room, small)).status, 409);
        assert.equal((await join('two', room, small)).status, 200);
        assert.equal((await join('three', room, small)).status, 429);
    } finally { await small.dispose(); }
});


test('ownership and WebSocket sender identity are enforced without exposing provider credentials', async () => {
    const other = 'another-device-token-with-at-least-32-characters';
    const otherHash = createHash('sha256').update(other).digest('hex');
    const instance = await makeRuntime({ CLIENT_TOKENS_JSON: JSON.stringify({ [hash]: 'tester', [otherHash]: 'other' }) });
    try {
        const a = await (await join('alice', room, instance)).json();
        const b = await (await join('bob', room, instance)).json();
        const base = `/api/rooms/${room}/sessions/`;
        assert.equal((await call(base + a.sessionId + '/renew', {}, 'POST', instance, other)).status, 403);
        const connect = id => instance.dispatchFetch('https://worker.test' + base + id + '/signal', {
            headers: { Authorization: `Bearer ${token}`, Upgrade: 'websocket' } });
        const ra = await connect(a.sessionId), rb = await connect(b.sessionId);
        assert.equal(ra.status, 101); assert.equal(rb.status, 101);
        ra.webSocket.accept(); rb.webSocket.accept();
        const received = new Promise((resolve, reject) => {
            const timeout = setTimeout(() => reject(new Error('message timeout')), 3000);
            rb.webSocket.addEventListener('message', e => {
                const d = JSON.parse(e.data);
                if (d.type === 'appData') { clearTimeout(timeout); resolve(d); }
            });
        });
        ra.webSocket.send(JSON.stringify({ type: 'appData', from: 'forged', namespace: 'test', payload: 'aGVsbG8=' }));
        assert.deepEqual(await received, { type: 'appData', from: 'alice', namespace: 'test', payload: 'aGVsbG8=' });
        ra.webSocket.close(); rb.webSocket.close();
        assert.equal((await call(base + a.sessionId + '/renew', {}, 'POST', instance)).status, 200);
    } finally { await instance.dispose(); }
});

test('expired lease alarm closes media and releases the active-session slot', async () => {
    const instance = await makeRuntime({ LEASE_SECONDS: '1' });
    try {
        const a = await (await join('expires', room, instance)).json();
        const deadline = Date.now() + 5000;
        let active = 1;
        while (Date.now() < deadline && active) {
            await new Promise(resolve => setTimeout(resolve, 100));
            active = (await (await call('/api/status', undefined, 'GET', instance)).json()).activeSessions;
        }
        assert.equal(active, 0);
        // Wait for the asynchronous alarm, not merely the usage index pruning.
        while (Date.now() < deadline && !provider.requests.some(r => r.url.includes(a.sessionId + '/tracks/close'))) {
            await new Promise(resolve => setTimeout(resolve, 100));
        }
        assert.ok(provider.requests.some(r => r.url.includes(a.sessionId + '/tracks/close')));
    } finally { await instance.dispose(); }
});

test('already expired provider session can be removed without an endless cleanup retry', async () => {
    const a = await (await join('gone', 'f'.repeat(64))).json();
    provider.upstreamGone = true;
    try {
        assert.equal((await call(`/api/rooms/${'f'.repeat(64)}/sessions/${a.sessionId}`, undefined, 'DELETE')).status, 200);
    } finally { provider.upstreamGone = false; }
});

test('repeated peer replacement reuses subscriber transceivers instead of growing SDP', async () => {
    const instance = await makeRuntime();
    try {
        const listener = await (await join('listener', room, instance)).json();
        for (let n = 0; n < 10; n++) {
            const talker = await (await join('talker', room, instance)).json();
            const base = `/api/rooms/${room}/sessions/${listener.sessionId}`;
            const response = await call(base + '/pull', { peerIds: ['talker'] }, 'POST', instance);
            assert.equal(response.status, 200);
            const result = await response.json();
            if (result.requiresImmediateRenegotiation) {
                assert.equal((await call(base + '/answer', { sessionDescription: { type: 'answer', sdp: offer.sdp } }, 'PUT', instance)).status, 200);
            }
            assert.equal((await call(`/api/rooms/${room}/sessions/${talker.sessionId}`, undefined, 'DELETE', instance)).status, 200);
        }
        const pulls = provider.requests.filter(r => r.url.includes(`/sessions/${listener.sessionId}/tracks/new`) && !r.body.sessionDescription);
        assert.equal(pulls.length, 1, 'Only the first subscription should allocate a receiving transceiver');
        assert.equal(provider.requests.filter(r => r.url.includes(`/sessions/${listener.sessionId}/tracks/update`)).length, 9);
    } finally { await instance.dispose(); }
});
