import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { token, hash, room, offer, provider, makeRuntime } from './support/runtime.mjs';
const request = (runtime, path, body, method = 'POST', credential = token) => runtime.dispatchFetch(`https://worker.test${path}`, {
    method, headers: { Authorization: `Bearer ${credential}`, 'Content-Type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
});
const tokenHash = value => createHash('sha256').update(value).digest('hex');

test('API budget covers rooms and status together, separates owners, and keeps authenticated cleanup reachable', async () => {
    const same = 'another-token-for-the-same-owner', other = 'token-for-a-different-owner';
    const runtime = await makeRuntime({ CLIENT_TOKENS_JSON: JSON.stringify({ [hash]: 'tester', [tokenHash(same)]: 'tester', [tokenHash(other)]: 'other' }) }, { apiLimit: 2 });
    try {
        assert.equal((await request(runtime, '/api/status', undefined, 'GET', 'invalid')).status, 401);
        const joined = await request(runtime, `/api/rooms/${room}/join`, { participantId: 'alice', offer });
        assert.equal(joined.status, 200);
        const base = `/api/rooms/${room}/sessions/${(await joined.json()).sessionId}`;
        assert.equal((await request(runtime, '/api/status', undefined, 'GET')).status, 200);
        const before = provider.requests.length;
        for (const [path, body, method] of [
            ['/api/status', undefined, 'GET'], [`/api/rooms/${'b'.repeat(64)}/join`, { participantId: 'new', offer }, 'POST'],
            [`/api/rooms/${room}/ice/new`, { leaseID: 'attempt' }, 'POST'],
            [base + '/publish', {}, 'POST'], [base + '/pull', { peerIds: [] }, 'POST'],
            [base + '/renew', {}, 'POST'], [base + '/signal', undefined, 'GET'],
            [base + '/signal', undefined, 'DELETE']
        ]) {
            const response = await request(runtime, path, body, method, same);
            assert.equal(response.status, 429, path);
            assert.equal(response.headers.get('Retry-After'), '60');
            assert.equal(response.headers.get('Cache-Control'), 'no-store');
            assert.equal((await response.json()).code, 'api_rate_limited');
        }
        assert.equal(provider.requests.length, before);
        assert.equal((await request(runtime, '/api/status', undefined, 'GET', other)).status, 200);
        assert.equal((await request(runtime, base, undefined, 'DELETE', other)).status, 403);
        assert.equal((await request(runtime, base, undefined, 'DELETE', 'invalid')).status, 401);
        assert.equal((await request(runtime, base, undefined, 'DELETE')).status, 200);
        assert.ok(provider.requests.length > before);
        assert.equal((await request(runtime, `/api/rooms/${room}/ice/new`, { leaseID: 'attempt' }, 'DELETE')).status, 200);
        assert.equal((await runtime.dispatchFetch('https://worker.test/health')).status, 200);
    } finally { await runtime.dispose(); }
});

test('missing API limiter fails closed for new work but does not block valid cleanup routes', async () => {
    const runtime = await makeRuntime({}, { apiLimit: false });
    try {
        const before = provider.requests.length;
        for (const [path, body, method] of [['/api/status', undefined, 'GET'], [`/api/rooms/${room}/join`, { participantId: 'alice', offer }, 'POST']]) {
            const response = await request(runtime, path, body, method);
            assert.equal(response.status, 503);
            assert.equal(response.headers.get('Retry-After'), '60');
            assert.equal(response.headers.get('Cache-Control'), 'no-store');
            assert.equal((await response.json()).code, 'api_rate_limit_unavailable');
        }
        assert.equal((await request(runtime, `/api/rooms/${room}/ice/new`, { leaseID: 'attempt' }, 'DELETE')).status, 200);
        assert.equal((await request(runtime, `/api/rooms/${room}/sessions/missing`, undefined, 'DELETE')).status, 404);
        assert.equal(provider.requests.length, before);
    } finally { await runtime.dispose(); }
});

test('default budget has headroom for eight participants, full subscriptions, renewals and frequent status reads', async () => {
    const runtime = await makeRuntime({ MAX_ROOM_PARTICIPANTS: '8' });
    try {
        const sessions = [];
        for (let i = 0; i < 8; i++) {
            assert.equal((await request(runtime, `/api/rooms/${room}/ice/rider-${i}`, { leaseID: `attempt-${i}` })).status, 200);
            const response = await request(runtime, `/api/rooms/${room}/join`, { participantId: `rider-${i}`, offer });
            assert.equal(response.status, 200);
            sessions.push((await response.json()).sessionId);
            assert.equal((await request(runtime, `/api/rooms/${room}/sessions/${sessions[i]}/publish`, {})).status, 200);
        }
        for (let i = 0; i < 8; i++) {
            const base = `/api/rooms/${room}/sessions/${sessions[i]}`;
            assert.equal((await request(runtime, base + '/pull', { peerIds: sessions.flatMap((_, j) => i === j ? [] : [`rider-${j}`]) })).status, 200);
            assert.equal((await request(runtime, base + '/renew', {})).status, 200);
        }
        for (let i = 0; i < 120; i++) assert.equal((await request(runtime, '/api/status', undefined, 'GET')).status, 200);
        for (const id of sessions) assert.equal((await request(runtime, `/api/rooms/${room}/sessions/${id}`, undefined, 'DELETE')).status, 200);
    } finally { await runtime.dispose(); }
});
