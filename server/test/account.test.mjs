import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { generateKeyPair, exportJWK, SignJWT } from 'jose';
import { makeRuntime, offer, room, provider } from './support/runtime.mjs';

const keys = await generateKeyPair('RS256');
const publicKey = { ...await exportJWK(keys.publicKey), kid: 'apple-fixture', alg: 'RS256', use: 'sig' };
const audience = 'com.yowamushi-inc.RideIntercom.RideIntercom';
const options = { APPLE_AUTH_ENABLED: 'true', APPLE_CLIENT_ID: audience, CLIENT_TOKENS_JSON: '{}' };
const call = (runtime, path, body, token, method = 'POST') => runtime.dispatchFetch(`https://worker.test${path}`, {
    method, headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': '192.0.2.10', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
});
async function challenge(runtime, deviceID = randomUUID()) {
    const response = await call(runtime, '/api/auth/apple/challenge', { deviceID });
    assert.equal(response.status, 200);
    return { ...await response.json(), deviceID };
}
async function proof(attempt, changes = {}, privateKey = keys.privateKey) {
    return new SignJWT({ nonce: attempt.nonce, email: 'private@example.invalid',
        iss: 'https://appleid.apple.com', aud: audience, sub: 'apple-private-subject',
        iat: Math.floor(Date.now() / 1000), exp: Math.floor(Date.now() / 1000) + 300, ...changes })
        .setProtectedHeader({ alg: 'RS256', kid: 'apple-fixture' }).sign(privateKey);
}
async function signIn(runtime, attempt, changes) {
    return call(runtime, '/api/auth/apple/session', { challengeID: attempt.challengeID, identityToken: await proof(attempt, changes) });
}

test('Apple enrollment gives one account across devices and authorizes individual device credentials', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        const a = await challenge(runtime), b = await challenge(runtime);
        const first = await signIn(runtime, a), second = await signIn(runtime, b);
        assert.equal(first.status, 200); assert.equal(second.status, 200);
        const one = await first.json(), two = await second.json();
        assert.equal(one.userID, two.userID);
        assert.match(one.userID, /^[a-f0-9]{64}$/);
        assert.equal(one.deviceID, a.deviceID);
        assert.notEqual(one.accessToken, two.accessToken);
        assert.ok(!JSON.stringify(one).includes('apple-private-subject'));
        assert.ok(!JSON.stringify(one).includes('private@example.invalid'));
        const session = await call(runtime, '/api/auth/session', undefined, one.accessToken, 'GET');
        assert.equal(session.status, 200);
        assert.deepEqual(await session.json(), { userID: one.userID, deviceID: a.deviceID, expiresAt: one.expiresAt });
        assert.equal((await call(runtime, '/api/status', undefined, one.accessToken, 'GET')).status, 200);
        const joined = await call(runtime, `/api/rooms/${room}/join`, { participantId: a.deviceID, offer }, one.accessToken);
        assert.equal(joined.status, 200);
        const media = await joined.json();
        assert.equal((await call(runtime, `/api/rooms/${room}/sessions/${media.sessionId}/renew`, {}, two.accessToken)).status, 403);
        assert.equal((await call(runtime, `/api/rooms/${room}/sessions/${media.sessionId}`, undefined, one.accessToken, 'DELETE')).status, 200);
        assert.equal((await call(runtime, '/api/auth/session', undefined, one.accessToken, 'DELETE')).status, 200);
        assert.equal((await call(runtime, '/api/status', undefined, one.accessToken, 'GET')).status, 401);
        assert.equal((await call(runtime, '/api/status', undefined, two.accessToken, 'GET')).status, 200);
    } finally { await runtime.dispose(); }
});

test('Apple proof rejects invalid claims and signatures without consuming the valid attempt', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        for (const claims of [{ nonce: 'wrong' }, { aud: 'another-app' }, { iss: 'https://attacker.invalid' },
            { exp: 1 }, { sub: '' }, { iat: Math.floor(Date.now() / 1000) + 3600 }, { nonce: undefined }]) {
            const attempt = await challenge(runtime);
            assert.equal((await signIn(runtime, attempt, claims)).status, 401);
        }
        const attempt = await challenge(runtime);
        const other = await generateKeyPair('RS256');
        assert.equal((await call(runtime, '/api/auth/apple/session', {
            challengeID: attempt.challengeID, identityToken: await proof(attempt, {}, other.privateKey)
        })).status, 401);
        assert.equal((await signIn(runtime, attempt)).status, 200);
        assert.equal((await signIn(runtime, attempt)).status, 401);
    } finally { await runtime.dispose(); }
});

test('a concurrent replay issues only one device credential', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        const attempt = await challenge(runtime);
        const body = { challengeID: attempt.challengeID, identityToken: await proof(attempt) };
        const results = await Promise.all([call(runtime, '/api/auth/apple/session', body), call(runtime, '/api/auth/apple/session', body)]);
        assert.deepEqual(results.map(r => r.status).sort(), [200, 401]);
    } finally { await runtime.dispose(); }
});

test('signing in again rotates only that device and another Apple user gets another account', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        const attempt = await challenge(runtime);
        const old = await (await signIn(runtime, attempt)).json();
        const next = await (await signIn(runtime, await challenge(runtime, attempt.deviceID))).json();
        const other = await (await signIn(runtime, await challenge(runtime), { sub: 'another-apple-subject' })).json();
        assert.equal(old.userID, next.userID);
        assert.notEqual(old.userID, other.userID);
        assert.equal((await call(runtime, '/api/status', undefined, old.accessToken, 'GET')).status, 401);
        assert.equal((await call(runtime, '/api/status', undefined, next.accessToken, 'GET')).status, 200);
        const parts = next.accessToken.split('.'); parts[2] = other.deviceID;
        assert.equal((await call(runtime, '/api/status', undefined, parts.join('.'), 'GET')).status, 401);
    } finally { await runtime.dispose(); }
});

test('enrollment fails closed without explicit enablement and invalid request bodies are bounded', async () => {
    const runtime = await makeRuntime();
    const enabled = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        assert.equal((await call(runtime, '/api/auth/apple/challenge', { deviceID: randomUUID() })).status, 503);
        for (const deviceID of ['', 1, '../device', 'x'.repeat(1000)]) {
            assert.equal((await call(enabled, '/api/auth/apple/challenge', { deviceID })).status, 400);
        }
        assert.equal((await call(enabled, '/api/auth/apple/session', { challengeID: 'bad', identityToken: 'x' })).status, 400);
        assert.equal((await call(enabled, '/api/auth/apple/challenge', { deviceID: randomUUID(), excess: 'x'.repeat(66000) })).status, 400);
    } finally { await runtime.dispose(); await enabled.dispose(); }
});

test('device secrets, Apple tokens, subject and email are not persisted', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-account-privacy-'));
    const runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey] });
    try {
        const attempt = await challenge(runtime);
        const identityToken = await proof(attempt);
        const response = await call(runtime, '/api/auth/apple/session', { challengeID: attempt.challengeID, identityToken });
        assert.equal(response.status, 200);
        const session = await response.json();
        const files = (await readdir(storageDirectory, { recursive: true })).filter(path => /\.sqlite(?:-wal)?$/.test(path));
        const bytes = Buffer.concat(await Promise.all(files.map(path => readFile(join(storageDirectory, path)))));
        assert.ok(bytes.includes(Buffer.from(attempt.deviceID)));
        for (const secret of [identityToken, session.accessToken.split('.').at(-1), 'apple-private-subject', 'private@example.invalid']) {
            assert.ok(!bytes.includes(Buffer.from(secret)));
        }
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('expired challenges and devices remain unusable after server restart', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-account-expiry-'));
    let runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey] });
    try {
        const attempt = await challenge(runtime);
        const session = await (await signIn(runtime, await challenge(runtime))).json();
        await runtime.dispose();
        runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey], clockOffsetMs: 301000 });
        assert.equal((await signIn(runtime, attempt)).status, 401);
        assert.equal((await call(runtime, '/api/auth/session', undefined, session.accessToken, 'GET')).status, 200);
        await runtime.dispose();
        runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey], clockOffsetMs: 31 * 86400000 });
        assert.equal((await call(runtime, '/api/auth/session', undefined, session.accessToken, 'GET')).status, 401);
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('device registration is bounded and a full account can still rotate an existing device', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        const first = await challenge(runtime);
        assert.equal((await signIn(runtime, first)).status, 200);
        for (let n = 1; n < 8; n++) assert.equal((await signIn(runtime, await challenge(runtime))).status, 200);
        const full = await signIn(runtime, await challenge(runtime));
        assert.equal(full.status, 409);
        assert.equal((await full.json()).code, 'device_limit_reached');
        assert.equal((await signIn(runtime, await challenge(runtime, first.deviceID))).status, 200);
    } finally { await runtime.dispose(); }
});

test('media pause does not prevent a signed-in device from revoking its credential', async () => {
    const runtime = await makeRuntime({ ...options, SERVICE_ENABLED: 'false' }, { appleKeys: [publicKey] });
    try {
        const session = await (await signIn(runtime, await challenge(runtime))).json();
        assert.equal((await call(runtime, '/api/status', undefined, session.accessToken, 'GET')).status, 503);
        assert.equal((await call(runtime, '/api/auth/session', undefined, session.accessToken, 'DELETE')).status, 200);
    } finally { await runtime.dispose(); }
});

test('enrollment limits requests before parsing and ignores client-selected forwarding identifiers', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        // Invalid input consumes the same source budget as valid input. Changing
        // device IDs, route, or X-Forwarded-For cannot reset that budget.
        for (let n = 0; n < 31; n++) {
            const response = await runtime.dispatchFetch(`https://worker.test/api/auth/apple/${n % 2 ? 'session' : 'challenge'}`, {
                method: 'POST', headers: { 'CF-Connecting-IP': '192.0.2.10', 'X-Forwarded-For': `198.51.100.${n}` }, body: '{}'
            });
            assert.equal(response.status, n < 30 ? 400 : 429);
            if (n === 30) {
                assert.equal(response.headers.get('Retry-After'), '60');
                assert.equal(response.headers.get('Cache-Control'), 'no-store');
                assert.equal((await response.json()).code, 'enrollment_rate_limited');
            }
        }
        assert.equal((await runtime.dispatchFetch('https://worker.test/api/auth/apple/challenge', {
            method: 'POST', headers: { 'CF-Connecting-IP': '192.0.2.11' }, body: JSON.stringify({ deviceID: randomUUID() })
        })).status, 200);
        assert.equal((await call(runtime, '/health', undefined, undefined, 'GET')).status, 200);
    } finally { await runtime.dispose(); }
});

test('aggregate enrollment limit also bounds changing source addresses', async () => {
    const runtime = await makeRuntime(options);
    try {
        for (let n = 0; n < 301; n++) {
            const response = await runtime.dispatchFetch('https://worker.test/api/auth/apple/challenge', {
                method: 'POST', headers: { 'CF-Connecting-IP': `2001:db8::${n.toString(16)}` }, body: '{}'
            });
            assert.equal(response.status, n < 300 ? 400 : 429);
        }
    } finally { await runtime.dispose(); }
});

test('missing abuse protection fails closed while session revocation stays available', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-account-limit-'));
    let runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey] });
    try {
        const session = await (await signIn(runtime, await challenge(runtime))).json();
        assert.equal((await runtime.dispatchFetch('https://worker.test/api/auth/apple/challenge', {
            // Miniflare fills an absent/empty source header; an invalid edge
            // value exercises the same fail-closed branch without that default.
            method: 'POST', headers: { 'CF-Connecting-IP': 'x'.repeat(65) }, body: JSON.stringify({ deviceID: randomUUID() })
        })).status, 503);
        await runtime.dispose();
        runtime = await makeRuntime(options, { storageDirectory, enrollmentLimits: false });
        assert.equal((await challengeResponse(runtime)).status, 503);
        assert.equal((await call(runtime, '/api/auth/session', undefined, session.accessToken, 'DELETE')).status, 200);
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});
const challengeResponse = runtime => call(runtime, '/api/auth/apple/challenge', { deviceID: randomUUID() });

test('challenge verification attempts are bounded across concurrent requests and restart', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-account-attempts-'));
    let runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey] });
    try {
        const attempt = await challenge(runtime);
        const replies = await Promise.all(Array.from({ length: 5 }, () => signIn(runtime, attempt, { nonce: 'wrong' })));
        assert.ok(replies.every(response => response.status === 401));
        await runtime.dispose();
        runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey] });
        assert.equal((await signIn(runtime, attempt)).status, 401);
        assert.equal((await signIn(runtime, await challenge(runtime))).status, 200);
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('throttling enrollment never blocks authenticated sign-out or existing service access', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        const session = await (await signIn(runtime, await challenge(runtime))).json();
        for (let n = 0; n < 30; n++) await challengeResponse(runtime);
        assert.equal((await challengeResponse(runtime)).status, 429);
        assert.equal((await call(runtime, '/api/status', undefined, session.accessToken, 'GET')).status, 200);
        assert.equal((await call(runtime, '/api/auth/session', undefined, session.accessToken, 'DELETE')).status, 200);
    } finally { await runtime.dispose(); }
});

async function enrolled(runtime, sub = 'apple-private-subject') {
    const response = await signIn(runtime, await challenge(runtime), { sub });
    assert.equal(response.status, 200);
    return response.json();
}

test('one public account reserves one connection across rooms, devices and forged identity headers', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        const accounts = [await enrolled(runtime), await enrolled(runtime)];
        const rooms = [room, 'b'.repeat(64)];
        provider.requests = [];
        const responses = await Promise.all(accounts.map((account, i) => call(runtime, `/api/rooms/${rooms[i]}/join`,
            { participantId: account.deviceID, offer }, account.accessToken)));
        assert.deepEqual(responses.map(r => r.status).sort(), [200, 409]);
        const winner = responses.findIndex(r => r.status === 200), loser = 1 - winner;
        const media = await responses[winner].json();
        assert.equal((await responses[loser].json()).code, 'account_in_use');
        assert.equal(provider.requests.filter(r => r.url.endsWith('/sessions/new')).length, 1);
        const forged = await runtime.dispatchFetch(`https://worker.test/api/rooms/${'c'.repeat(64)}/join`, {
            method: 'POST', headers: { Authorization: `Bearer ${accounts[winner].accessToken}`, 'Content-Type': 'application/json',
                'X-User': 'd'.repeat(64), 'X-Owner': 'someone-else' }, body: JSON.stringify({ participantId: 'new-peer', offer })
        });
        assert.equal(forged.status, 409);
        assert.equal((await forged.json()).code, 'account_in_use');
        const path = `/api/rooms/${rooms[winner]}/sessions/${media.sessionId}`;
        assert.equal((await call(runtime, path + '/renew', {}, accounts[winner].accessToken)).status, 200);
        const independent = await enrolled(runtime, 'other-person');
        assert.equal((await call(runtime, `/api/rooms/${rooms[winner]}/join`, { participantId: independent.deviceID, offer }, independent.accessToken)).status, 200);
        assert.equal((await call(runtime, path, undefined, accounts[winner].accessToken, 'DELETE')).status, 200);
        assert.equal((await call(runtime, `/api/rooms/${rooms[loser]}/join`, { participantId: accounts[loser].deviceID, offer }, accounts[loser].accessToken)).status, 200);
    } finally { await runtime.dispose(); }
});

const turnOptions = { ...options, TURN_ENABLED: 'true', CLOUDFLARE_TURN_KEY_ID: 'test-key', CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret' };
test('TURN preparation owns the same account slot as join and renewal, and cancellation frees it', async () => {
    const runtime = await makeRuntime(turnOptions, { appleKeys: [publicKey] });
    try {
        const one = await enrolled(runtime), two = await enrolled(runtime);
        const ice = `/api/rooms/${room}/ice/${one.deviceID}`;
        assert.equal((await call(runtime, ice, { leaseID: 'first' }, one.accessToken)).status, 200);
        const count = provider.requests.length;
        assert.equal((await call(runtime, ice, { leaseID: 'first' }, one.accessToken)).status, 200);
        assert.equal((await call(runtime, `/api/rooms/${'b'.repeat(64)}/ice/${two.deviceID}`, { leaseID: 'second' }, two.accessToken)).status, 409);
        assert.equal(provider.requests.length, count);
        assert.equal((await call(runtime, ice, { leaseID: 'first' }, one.accessToken, 'DELETE')).status, 200);
        const nextIce = `/api/rooms/${room}/ice/${two.deviceID}`;
        assert.equal((await call(runtime, nextIce, { leaseID: 'second' }, two.accessToken)).status, 200);
        const joined = await call(runtime, `/api/rooms/${room}/join`, { participantId: two.deviceID, offer, iceLeaseID: 'second' }, two.accessToken);
        assert.equal(joined.status, 200);
        const media = await joined.json();
        assert.equal((await call(runtime, `/api/rooms/${room}/sessions/${media.sessionId}/renew`, {}, two.accessToken)).status, 200);
    } finally { await runtime.dispose(); }
});

test('public account connection reservations survive restart and expire with their lease', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-account-connection-'));
    let runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey] });
    try {
        const one = await enrolled(runtime), two = await enrolled(runtime);
        assert.equal((await call(runtime, `/api/rooms/${room}/join`, { participantId: one.deviceID, offer }, one.accessToken)).status, 200);
        await runtime.dispose();
        runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey] });
        const target = `/api/rooms/${'b'.repeat(64)}/join`, body = { participantId: two.deviceID, offer };
        assert.equal((await call(runtime, target, body, two.accessToken)).status, 409);
        await runtime.dispose();
        runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey], clockOffsetMs: 601000 });
        assert.equal((await call(runtime, target, body, two.accessToken)).status, 200);
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('failed TURN cleanup retains the account slot until cleanup succeeds', async () => {
    const runtime = await makeRuntime(turnOptions, { appleKeys: [publicKey] });
    try {
        const one = await enrolled(runtime), two = await enrolled(runtime);
        const ice = `/api/rooms/${room}/ice/${one.deviceID}`;
        assert.equal((await call(runtime, ice, { leaseID: 'first' }, one.accessToken)).status, 200);
        provider.revokeFails = true;
        assert.equal((await call(runtime, ice, { leaseID: 'first' }, one.accessToken, 'DELETE')).status, 502);
        assert.equal((await call(runtime, `/api/rooms/${'b'.repeat(64)}/ice/${two.deviceID}`, { leaseID: 'second' }, two.accessToken)).status, 409);
        provider.revokeFails = false;
        assert.equal((await call(runtime, ice, { leaseID: 'first' }, one.accessToken, 'DELETE')).status, 200);
        assert.equal((await call(runtime, `/api/rooms/${'b'.repeat(64)}/ice/${two.deviceID}`, { leaseID: 'second' }, two.accessToken)).status, 200);
    } finally { provider.revokeFails = false; await runtime.dispose(); }
});


test('a failed SFU setup keeps its account slot until the room alarm completes cleanup', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        const one = await enrolled(runtime), two = await enrolled(runtime);
        provider.establishFails = true;
        assert.equal((await call(runtime, `/api/rooms/${room}/join`, { participantId: one.deviceID, offer }, one.accessToken)).status, 502);
        assert.equal((await call(runtime, `/api/rooms/${'b'.repeat(64)}/join`, { participantId: two.deviceID, offer }, two.accessToken)).status, 409);
        provider.establishFails = false;
        let active;
        for (let i = 0; i < 60; i++) {
            active = (await (await call(runtime, '/api/status', undefined, one.accessToken, 'GET')).json()).activeSessions;
            if (active === 0) break;
            await new Promise(resolve => setTimeout(resolve, 50));
        }
        assert.equal(active, 0, 'The room alarm must release the failed session reservation');
        assert.equal((await call(runtime, `/api/rooms/${'b'.repeat(64)}/join`, { participantId: two.deviceID, offer }, two.accessToken)).status, 200);
    } finally { provider.establishFails = false; await runtime.dispose(); }
});


test('account deletion removes every device of only the authenticated account and retries safely', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        const one = await enrolled(runtime), two = await enrolled(runtime), other = await enrolled(runtime, 'different-person');
        const oldAttempt = await challenge(runtime);
        const responses = await Promise.all([0, 1].map(() => call(runtime, '/api/auth/account', undefined, one.accessToken, 'DELETE')));
        assert.deepEqual(responses.map(r => r.status), [200, 200]);
        assert.deepEqual(await responses[0].json(), { deleted: true, appleAuthorizationRevoked: false });
        for (const credential of [one, two]) assert.equal((await call(runtime, '/api/auth/session', undefined, credential.accessToken, 'GET')).status, 401);
        assert.equal((await call(runtime, '/api/auth/session', undefined, other.accessToken, 'GET')).status, 200);
        assert.equal((await signIn(runtime, oldAttempt)).status, 401, 'A proof issued before deletion must not recreate device access');
        const replacement = await enrolled(runtime);
        assert.equal((await call(runtime, '/api/auth/account', undefined, one.accessToken, 'DELETE')).status, 200);
        assert.equal((await call(runtime, '/api/auth/session', undefined, replacement.accessToken, 'GET')).status, 200, 'A repeated old deletion must not delete new registrations');
        assert.equal((await call(runtime, '/api/auth/account', undefined, two.accessToken, 'DELETE')).status, 401);
    } finally { await runtime.dispose(); }
});

test('account deletion receipt survives restart, expires, and still works with enrollment disabled', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-account-deletion-'));
    let runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey] });
    try {
        const one = await enrolled(runtime);
        assert.equal((await call(runtime, '/api/auth/account', undefined, one.accessToken, 'GET')).status, 405);
        assert.equal((await call(runtime, '/api/auth/account', undefined, 'invalid', 'DELETE')).status, 401);
        await runtime.dispose();
        runtime = await makeRuntime({ ...options, APPLE_AUTH_ENABLED: 'false', SERVICE_ENABLED: 'false' }, { storageDirectory, appleKeys: [publicKey] });
        assert.equal((await call(runtime, '/api/auth/account', undefined, one.accessToken, 'DELETE')).status, 200);
        await runtime.dispose();
        runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey] });
        assert.equal((await call(runtime, '/api/auth/account', undefined, one.accessToken, 'DELETE')).status, 200);
        const replacement = await enrolled(runtime);
        await runtime.dispose();
        runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey], clockOffsetMs: 86401000 });
        assert.equal((await call(runtime, '/api/auth/account', undefined, one.accessToken, 'DELETE')).status, 401);
        assert.equal((await call(runtime, '/api/auth/session', undefined, replacement.accessToken, 'GET')).status, 200);
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});
