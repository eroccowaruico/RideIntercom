import { test } from 'node:test';
import assert from 'node:assert/strict';
import { token, room, offer, provider, makeRuntime } from './support/runtime.mjs';
const call = (runtime, path, body, method = 'POST', credential = token) => runtime.dispatchFetch(`https://worker.test/api/rooms/${room}/${path}`, {
    method, headers: { Authorization: `Bearer ${credential}`, 'Content-Type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
const leaseID = 'test-attempt-1';

test('TURN preflight is quota guarded, owned, idempotent and revoked on disconnect', async () => {
    const runtime = await makeRuntime({ TURN_ENABLED: 'true', CLOUDFLARE_TURN_KEY_ID: 'test-turn', CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret' });
    try {
        provider.requests = [];
        assert.equal((await call(runtime, 'ice/alice', { leaseID }, 'POST', 'bad')).status, 401);
        assert.equal(provider.requests.length, 0);
        const first = await call(runtime, 'ice/alice', { leaseID });
        assert.equal(first.status, 200);
        const ice = await first.json();
        assert.ok(ice.iceServers.some(s => s.urls.some(u => u.startsWith('turn:'))));
        assert.equal(JSON.stringify(ice).includes('test-turn-secret'), false);
        await call(runtime, 'ice/alice', { leaseID });
        assert.equal(provider.requests.filter(r => r.url.includes('generate-ice-servers')).length, 1);
        assert.equal((await call(runtime, 'ice/alice', { leaseID: 'old-attempt' }, 'DELETE')).status, 409);
        const joined = await call(runtime, 'join', { participantId: 'alice', offer, iceLeaseID: leaseID });
        assert.equal(joined.status, 200);
        const lease = await joined.json();
        assert.equal((await call(runtime, `sessions/${lease.sessionId}`, undefined, 'DELETE')).status, 200);
        assert.ok(provider.requests.some(r => r.url.endsWith('/revoke')));
    } finally { await runtime.dispose(); }
});

test('TURN preflight cannot exceed quota or silently fall back when misconfigured', async () => {
    const runtime = await makeRuntime({ TURN_ENABLED: 'true', CLOUDFLARE_TURN_KEY_ID: 'test-turn', CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret', MONTHLY_PARTICIPANT_SECONDS: '600' });
    try {
        assert.equal((await call(runtime, 'ice/a', { leaseID })).status, 200);
        const count = provider.requests.length;
        assert.equal((await call(runtime, 'ice/b', { leaseID: 'another' })).status, 429);
        assert.equal(provider.requests.length, count);
        assert.equal((await call(runtime, 'ice/a', { leaseID }, 'DELETE')).status, 200);
    } finally { await runtime.dispose(); }
    const broken = await makeRuntime({ TURN_ENABLED: 'true' });
    try { assert.equal((await call(broken, 'ice/a', { leaseID })).status, 503); }
    finally { await broken.dispose(); }
});


test('TURN renewal keeps the SFU session and retires all issued credentials at disconnect', async () => {
    const runtime = await makeRuntime({ TURN_ENABLED: 'true', CLOUDFLARE_TURN_KEY_ID: 'test-turn', CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret', LEASE_SECONDS: '4' });
    try {
        provider.requests = [];
        assert.equal((await call(runtime, 'ice/a', { leaseID })).status, 200);
        const lease = await (await call(runtime, 'join', { participantId: 'a', offer, iceLeaseID: leaseID })).json();
        await new Promise(resolve => setTimeout(resolve, 2100));
        const renewed = await (await call(runtime, `sessions/${lease.sessionId}/renew`, {})).json();
        assert.equal(renewed.sessionId, lease.sessionId);
        assert.ok(renewed.iceServers.some(s => s.username));
        const issues = provider.requests.filter(r => r.url.includes('/generate-ice-servers'));
        assert.equal(issues.length, 2);
        assert.ok(issues.every(r => r.body.ttl <= 8));
        assert.equal(provider.requests.filter(r => r.url.endsWith('/sessions/new')).length, 1);
        assert.equal((await call(runtime, `sessions/${lease.sessionId}`, undefined, 'DELETE')).status, 200);
        assert.equal(provider.requests.filter(r => r.url.endsWith('/revoke')).length, 2);
    } finally { await runtime.dispose(); }
});

test('abandoned preflight expires without creating an SFU session', async () => {
    const runtime = await makeRuntime({ TURN_ENABLED: 'true', CLOUDFLARE_TURN_KEY_ID: 'test-turn', CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret', LEASE_SECONDS: '1' });
    try {
        provider.requests = [];
        assert.equal((await call(runtime, 'ice/abandoned', { leaseID })).status, 200);
        await new Promise(resolve => setTimeout(resolve, 2200));
        assert.equal((await call(runtime, 'ice/abandoned', { leaseID: 'next-attempt' })).status, 200);
        assert.equal(provider.requests.some(r => r.url.endsWith('/sessions/new')), false);
    } finally { await runtime.dispose(); }
});


test('failed revocation retains cleanup and is retried instead of abandoning credentials', async () => {
    const runtime = await makeRuntime({ TURN_ENABLED: 'true', CLOUDFLARE_TURN_KEY_ID: 'test-turn', CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret' });
    try {
        await call(runtime, 'ice/retry', { leaseID });
        provider.revokeFails = true;
        assert.equal((await call(runtime, 'ice/retry', { leaseID }, 'DELETE')).status, 502);
        provider.revokeFails = false;
        await new Promise(resolve => setTimeout(resolve, 1800));
        assert.equal((await call(runtime, 'ice/retry', { leaseID: 'new-attempt' })).status, 200);
    } finally { provider.revokeFails = false; await runtime.dispose(); }
});


test('orphan credential cleanup does not serialize upstream delays across participants', async () => {
    const runtime = await makeRuntime({ TURN_ENABLED: 'true', CLOUDFLARE_TURN_KEY_ID: 'test-turn', CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret' });
    let active = 0, peak = 0;
    try {
        for (const peer of ['orphan-a', 'orphan-b']) await call(runtime, `ice/${peer}`, { leaseID });
        provider.revokeFails = true;
        for (const peer of ['orphan-a', 'orphan-b']) assert.equal((await call(runtime, `ice/${peer}`, { leaseID }, 'DELETE')).status, 502);
        provider.revokeFails = false;
        provider.onRevoke = async () => {
            peak = Math.max(peak, ++active);
            await new Promise(resolve => setTimeout(resolve, 200));
            active--;
        };
        await new Promise(resolve => setTimeout(resolve, 2200));
        assert.equal(peak, 2, 'alarm should overlap independent revocations');
        for (const peer of ['orphan-a', 'orphan-b']) assert.equal((await call(runtime, `ice/${peer}`, { leaseID: 'next-attempt' })).status, 200);
    } finally { provider.revokeFails = false; provider.onRevoke = undefined; await runtime.dispose(); }
});
