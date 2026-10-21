import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { Miniflare, Response } from 'miniflare';

const token = 'test-device-token-with-at-least-32-characters';
const hash = createHash('sha256').update(token).digest('hex');
const room = 'a'.repeat(64);
const offer = { type: 'offer', sdp: 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\na=rtpmap:111 opus/48000/2\r\n' };
let runtime, requests = [], serial = 0, upstreamFails = false, upstreamGone = false;
async function makeRuntime(overrides = {}) {
    const instance = new Miniflare({ modules: true, scriptPath: 'dist/index.js', compatibilityDate: '2024-11-01',
        durableObjects: { SIGNALING_ROOM: { className: 'SignalingRoom', useSQLite: true }, USAGE_GUARD: { className: 'UsageGuard', useSQLite: true } },
        bindings: { SERVICE_ENABLED: 'true', CLIENT_TOKENS_JSON: JSON.stringify({ [hash]: 'tester' }),
            CLOUDFLARE_SFU_APP_ID: 'test-app', CLOUDFLARE_SFU_APP_SECRET: 'test-secret',
            MAX_ROOM_PARTICIPANTS: '4', MAX_ACTIVE_SESSIONS: '16', MONTHLY_PARTICIPANT_SECONDS: '36000', LEASE_SECONDS: '600', ...overrides },
        outboundService: async request => {
            const text = await request.text();
            requests.push({ url: request.url, method: request.method, body: text ? JSON.parse(text) : undefined });
            assert.equal(request.headers.get('Authorization'), 'Bearer test-secret');
            const url = new URL(request.url);
            assert.equal(url.hostname, 'rtc.live.cloudflare.com');
            if (upstreamGone) return Response.json({}, { status: 410 });
            if (upstreamFails) return Response.json({ errorCode: 'failure' }, { status: 503 });
            if (url.pathname.endsWith('/sessions/new')) return Response.json({ sessionId: `sfu-${++serial}` }, { status: 201 });
            if (url.pathname.endsWith('/tracks/new')) {
                const body = requests.at(-1).body;
                return Response.json({ sessionDescription: { type: body.sessionDescription ? 'answer' : 'offer', sdp: 'mock-sfu-sdp' },
                    requiresImmediateRenegotiation: !body.sessionDescription,
                    tracks: body.tracks.map((t, i) => ({ ...t, mid: String(i + (t.location === 'remote' ? 1 : 0)) })) });
            }
            if (url.pathname.endsWith('/renegotiate') || url.pathname.endsWith('/tracks/close')) return Response.json({});
            return Response.json({ tracks: [{ mid: '0' }, { mid: '1' }] });
        }
    });
    await instance.ready; return instance;
}
before(async () => { runtime = await makeRuntime(); });
after(async () => { await runtime?.dispose(); });
const call = (path, body, method = 'POST', instance = runtime, credential = token) => instance.dispatchFetch(`https://worker.test${path}`, {
    method, headers: { Authorization: `Bearer ${credential}`, 'Content-Type': 'application/json' }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
const join = (id, target = room, instance = runtime) => call(`/api/rooms/${target}/join`, { participantId: id, displayName: id, offer }, 'POST', instance);

test('unauthenticated and malformed requests never contact the provider', async () => {
    requests = [];
    assert.equal((await runtime.dispatchFetch('https://worker.test/health')).status, 200);
    assert.equal((await call(`/api/rooms/${room}/join`, {}, 'POST', runtime, 'invalid')).status, 401);
    assert.equal((await call(`/api/rooms/${room}/join`, { participantId: 'x', offer: { ...offer, sdp: offer.sdp + 'm=video 9 RTP/AVP 96\r\n' } })).status, 400);
    assert.equal((await call('/api/rooms/guessable/join', {})).status, 400);
    assert.equal(requests.length, 0);
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
    const before = requests.length;
    const renewed = await (await call(base + '/renew', {})).json();
    assert.equal(renewed.sessionId, a.sessionId); assert.equal(requests.length, before);
    assert.equal((await call(base + '/pull', { peerIds: ['not-in-room'] })).status, 403);
    assert.equal((await call(`/api/rooms/${'b'.repeat(64)}/sessions/${a.sessionId}/renew`, {})).status, 404);
    assert.equal((await call(base, undefined, 'DELETE')).status, 200);
    assert.equal((await call(`/api/rooms/${room}/sessions/${b.sessionId}`, undefined, 'DELETE')).status, 200);
    assert.ok(requests.some(r => r.url.endsWith('/tracks/close') && r.body.force === true));
});

test('quota reservations survive concurrent requests and prevent provider calls', async () => {
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
    upstreamFails = true;
    try { assert.equal((await join('failed', 'e'.repeat(64))).status, 502); } finally { upstreamFails = false; }
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
        while (Date.now() < deadline && !requests.some(r => r.url.includes(a.sessionId + '/tracks/close'))) {
            await new Promise(resolve => setTimeout(resolve, 100));
        }
        assert.ok(requests.some(r => r.url.includes(a.sessionId + '/tracks/close')));
    } finally { await instance.dispose(); }
});

test('already expired provider session can be removed without an endless cleanup retry', async () => {
    const a = await (await join('gone', 'f'.repeat(64))).json();
    upstreamGone = true;
    try {
        assert.equal((await call(`/api/rooms/${'f'.repeat(64)}/sessions/${a.sessionId}`, undefined, 'DELETE')).status, 200);
    } finally { upstreamGone = false; }
});
