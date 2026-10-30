import { test } from 'node:test';
import WebSocket from 'ws';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { generateKeyPair, exportJWK, SignJWT, jwtVerify } from 'jose';
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
        assert.notEqual(one.userID, one.accessToken.split('.')[1], 'Public identity must not expose the private account locator');
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
        assert.notEqual(replacement.userID, one.userID, 'Deletion must retire the previous public identity');
        const replay = await call(runtime, '/api/auth/account', undefined, one.accessToken, 'DELETE');
        assert.equal(replay.status, 200);
        assert.deepEqual(await replay.json(), { deleted: true, appleAuthorizationRevoked: false, newerAccountPreserved: true });
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
        assert.notEqual(replacement.userID, one.userID, 'Deletion must retire the previous public identity');
        await runtime.dispose();
        runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey], clockOffsetMs: 86401000 });
        assert.equal((await call(runtime, '/api/auth/account', undefined, one.accessToken, 'DELETE')).status, 401);
        assert.equal((await call(runtime, '/api/auth/session', undefined, replacement.accessToken, 'GET')).status, 200);
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});


test('public identity survives all-device sign-out and expiry, but not account deletion', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-public-identity-'));
    let runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey] });
    try {
        const one = await enrolled(runtime);
        assert.equal((await call(runtime, '/api/auth/session', undefined, one.accessToken, 'DELETE')).status, 200);
        const again = await enrolled(runtime);
        assert.equal(again.userID, one.userID);
        await runtime.dispose();
        const offset = 31 * 86400000;
        runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey], clockOffsetMs: offset });
        assert.equal((await call(runtime, '/api/auth/session', undefined, again.accessToken, 'GET')).status, 401);
        const now = Math.floor((Date.now() + offset) / 1000);
        const restoredResponse = await signIn(runtime, await challenge(runtime), { iat: now, exp: now + 300 });
        assert.equal(restoredResponse.status, 200);
        const restored = await restoredResponse.json();
        assert.equal(restored.userID, one.userID, 'Credential expiry is not account deletion');
        assert.equal((await call(runtime, '/api/auth/account', undefined, restored.accessToken, 'DELETE')).status, 200);
        const attempts = await Promise.all([challenge(runtime), challenge(runtime)]);
        const replacements = await Promise.all(attempts.map(attempt => signIn(runtime, attempt, { iat: now, exp: now + 300 })));
        assert.ok(replacements.every(response => response.status === 200));
        const identities = await Promise.all(replacements.map(response => response.json()));
        assert.notEqual(identities[0].userID, one.userID);
        assert.equal(identities[0].userID, identities[1].userID, 'Concurrent enrollment must share the new identity');
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('re-enrollment waits until failed SFU deletion cleanup completes', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        const one = await enrolled(runtime);
        assert.equal((await call(runtime, `/api/rooms/${room}/join`, { participantId: one.deviceID, offer }, one.accessToken)).status, 200);
        provider.upstreamFails = true;
        const deletion = await call(runtime, '/api/auth/account', undefined, one.accessToken, 'DELETE');
        assert.equal(deletion.status, 200);
        assert.equal((await deletion.json()).mediaCleanupPending, true);
        const count = provider.requests.length;
        const registration = await signIn(runtime, await challenge(runtime));
        assert.equal(registration.status, 409);
        assert.equal((await registration.json()).code, 'deletion_pending');
        assert.equal(provider.requests.length, count);
        assert.equal((await call(runtime, '/api/auth/session', undefined, one.accessToken, 'GET')).status, 401);
    } finally { provider.upstreamFails = false; await runtime.dispose(); }
});


test('device identity certificate binds only authenticated user and device to a public signing key', async () => {
    const signer = await generateKeyPair('ES256', { extractable: true });
    const signingJWK = await exportJWK(signer.privateKey);
    const deviceKeys = await generateKeyPair('ES256', { extractable: true });
    const deviceKey = Buffer.from(await crypto.subtle.exportKey('raw', deviceKeys.publicKey)).toString('base64url');
    const runtime = await makeRuntime({ ...options, DEVICE_IDENTITY_SIGNING_KEY: JSON.stringify(signingJWK) }, { appleKeys: [publicKey] });
    try {
        const one = await enrolled(runtime);
        const providerCount = provider.requests.length;
        const response = await call(runtime, '/api/auth/identity', { memberID: 'member-fixture', deviceKey, userID: 'forged-user', deviceID: randomUUID() }, one.accessToken);
        assert.equal(response.status, 200);
        const result = await response.json();
        assert.equal(result.issuerKey, Buffer.from(await crypto.subtle.exportKey('raw', signer.publicKey)).toString('base64url'));
        const { payload, protectedHeader } = await jwtVerify(result.certificate, signer.publicKey, {
            issuer: 'https://worker.test', audience: 'rideintercom-peer', algorithms: ['ES256'], typ: 'rideintercom-device+jwt'
        });
        assert.deepEqual(Object.keys(protectedHeader).sort(), ['alg', 'typ']);
        assert.equal(payload.sub, one.userID); assert.equal(payload.deviceID, one.deviceID);
        assert.equal(payload.memberID, 'member-fixture'); assert.equal(payload.deviceKey, deviceKey);
        assert.ok(payload.exp * 1000 <= one.expiresAt && payload.exp > payload.iat);
        const serialized = JSON.stringify(result);
        for (const secret of [one.accessToken, one.accessToken.split('.')[1], signingJWK.d, 'apple-private-subject', 'private@example.invalid']) assert.ok(!serialized.includes(secret));
        assert.equal(provider.requests.length, providerCount);
        assert.equal((await call(runtime, '/api/auth/account', undefined, one.accessToken, 'DELETE')).status, 200);
        assert.equal((await call(runtime, '/api/auth/identity', { memberID: 'member-fixture', deviceKey }, one.accessToken)).status, 401);
        const replacement = await enrolled(runtime);
        const renewed = await call(runtime, '/api/auth/identity', { memberID: 'member-fixture', deviceKey }, replacement.accessToken);
        assert.equal(renewed.status, 200);
        const next = await jwtVerify((await renewed.json()).certificate, signer.publicKey);
        assert.notEqual(next.payload.sub, payload.sub);
    } finally { await runtime.dispose(); }
});

test('device identity issuance rejects invalid keys, identifiers and unconfigured signing', async () => {
    const signer = await generateKeyPair('ES256', { extractable: true });
    const deviceKey = Buffer.from(await crypto.subtle.exportKey('raw', signer.publicKey)).toString('base64url');
    const runtime = await makeRuntime({ ...options, DEVICE_IDENTITY_SIGNING_KEY: JSON.stringify(await exportJWK(signer.privateKey)) }, { appleKeys: [publicKey] });
    const disabled = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        const one = await enrolled(runtime), other = await enrolled(disabled);
        const valid = { memberID: 'member-fixture', deviceKey };
        assert.equal((await call(disabled, '/api/auth/identity', valid, other.accessToken)).status, 503);
        assert.equal((await call(runtime, '/api/auth/identity', valid, 'invalid')).status, 401);
        assert.equal((await call(runtime, '/api/auth/identity', undefined, one.accessToken, 'GET')).status, 405);
        for (const body of [{ ...valid, deviceKey: 'invalid' }, { ...valid, deviceKey: Buffer.alloc(65).toString('base64url') },
            { ...valid, memberID: '' }, { ...valid, memberID: 'invite-pending-test' }, { ...valid, memberID: 'x'.repeat(64) }]) {
            assert.equal((await call(runtime, '/api/auth/identity', body, one.accessToken)).status, 400);
        }
    } finally { await runtime.dispose(); await disabled.dispose(); }
});

test('deletion verifies Apple code ownership and revokes before reporting completion', async () => {
    const runtime = await makeRuntime({ ...options, APPLE_CLIENT_SECRET: 'test-client-secret' }, { appleKeys: [publicKey], appleAuthorization: async (path, form) => {
        assert.equal(form.get('client_id'), audience); assert.equal(form.get('client_secret'), 'test-client-secret');
        if (path.endsWith('/token')) {
            assert.equal(form.get('grant_type'), 'authorization_code');
            assert.equal(form.get('code'), 'delete-code');
            return Response.json({ refresh_token: 'delete-refresh', id_token: await proof(deletionProof) });
        }
        assert.equal(path, '/auth/revoke'); assert.equal(form.get('token'), 'delete-refresh');
        assert.equal(form.get('token_type_hint'), 'refresh_token'); revoked++;
        return new Response(null, { status: 200 });
    } });
    let deletionProof, revoked = 0;
    try {
        const user = await enrolled(runtime);
        deletionProof = await challenge(runtime, user.deviceID);
        const body = { challengeID: deletionProof.challengeID, identityToken: await proof(deletionProof), authorizationCode: 'delete-code' };
        const response = await call(runtime, '/api/auth/account', body, user.accessToken, 'DELETE');
        assert.equal(response.status, 200);
        assert.deepEqual(await response.json(), { deleted: true, appleAuthorizationRevoked: true });
        assert.equal(revoked, 1);
        assert.equal((await call(runtime, '/api/auth/session', undefined, user.accessToken, 'GET')).status, 401);
        const replacement = await enrolled(runtime);
        assert.equal((await call(runtime, '/api/auth/account', body, user.accessToken, 'DELETE')).status, 200);
        assert.equal(revoked, 1, 'Old deletion must not revoke a newly registered Apple authorization');
        assert.equal((await call(runtime, '/api/auth/session', undefined, replacement.accessToken, 'GET')).status, 200);
    } finally { await runtime.dispose(); }
});

test('Apple revocation failure persists and blocks re-enrollment until retry succeeds', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-apple-revoke-'));
    let attempt, fail = true, tokens = 0, revocations = 0;
    const appleAuthorization = async path => {
        if (path.endsWith('/token')) { tokens++; return Response.json({ refresh_token: 'retry-token', id_token: await proof(attempt) }); }
        revocations++; return new Response(null, { status: fail ? 503 : 200 });
    };
    const config = { ...options, APPLE_CLIENT_SECRET: 'test-client-secret' };
    let runtime = await makeRuntime(config, { storageDirectory, appleKeys: [publicKey], appleAuthorization });
    try {
        const user = await enrolled(runtime);
        attempt = await challenge(runtime, user.deviceID);
        const response = await call(runtime, '/api/auth/account', { challengeID: attempt.challengeID,
            identityToken: await proof(attempt), authorizationCode: 'code' }, user.accessToken, 'DELETE');
        assert.equal(response.status, 200);
        assert.deepEqual(await response.json(), { deleted: true, appleAuthorizationRevoked: false, appleRevocationPending: true });
        assert.equal((await call(runtime, '/api/auth/session', undefined, user.accessToken, 'GET')).status, 401);
        for (let n = 0; n < 3; n++) assert.equal((await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE')).status, 200);
        assert.equal(revocations, 1); assert.equal(tokens, 1);
        const blocked = await signIn(runtime, await challenge(runtime));
        assert.equal(blocked.status, 409); assert.equal((await blocked.json()).code, 'deletion_pending');
        await runtime.dispose(); fail = false;
        runtime = await makeRuntime(config, { storageDirectory, appleKeys: [publicKey], appleAuthorization, clockOffsetMs: 61000 });
        const retried = await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE');
        assert.equal(retried.status, 200); assert.deepEqual(await retried.json(), { deleted: true, appleAuthorizationRevoked: true });
        assert.equal(tokens, 1, 'Consumed authorization code is not exchanged again');
        assert.equal(revocations, 2);
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('deletion rejects another account, token subject, redirects and oversized Apple responses', async () => {
    let attempt, mode = 'other-subject', tokens = 0, revocations = 0;
    const runtime = await makeRuntime({ ...options, APPLE_CLIENT_SECRET: 'test-client-secret' }, { appleKeys: [publicKey], appleAuthorization: async path => {
        if (path.endsWith('/revoke')) { revocations++; return new Response(null, { status: 200 }); }
        tokens++;
        if (mode === 'redirect') return new Response(null, { status: 302, headers: { Location: 'https://other.invalid/token' } });
        if (mode === 'large') return new Response('x'.repeat(32769), { status: 200 });
        return Response.json({ refresh_token: 'other-token', id_token: await proof(attempt, { sub: 'other-person' }) });
    } });
    try {
        const user = await enrolled(runtime);
        attempt = await challenge(runtime, user.deviceID);
        const wrong = await call(runtime, '/api/auth/account', { challengeID: attempt.challengeID,
            identityToken: await proof(attempt, { sub: 'other-person' }), authorizationCode: 'code' }, user.accessToken, 'DELETE');
        assert.equal(wrong.status, 401); assert.equal(tokens, 0);
        for (mode of ['other-subject', 'redirect', 'large']) {
            attempt = await challenge(runtime, user.deviceID);
            const response = await call(runtime, '/api/auth/account', { challengeID: attempt.challengeID,
                identityToken: await proof(attempt), authorizationCode: 'code' }, user.accessToken, 'DELETE');
            assert.equal(response.status, 503);
            assert.equal((await call(runtime, '/api/auth/session', undefined, user.accessToken, 'GET')).status, 200);
        }
        assert.equal(revocations, 0);
        const plain = await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE');
        assert.deepEqual(await plain.json(), { deleted: true, appleAuthorizationRevoked: false });
    } finally { await runtime.dispose(); }
});

test('concurrent deletion preparation cannot mint a second Apple grant', async () => {
    let attempt, tokens = 0, entered, release;
    const waiting = new Promise(resolve => { entered = resolve; });
    const gate = new Promise(resolve => { release = resolve; });
    const runtime = await makeRuntime({ ...options, APPLE_CLIENT_SECRET: 'test-client-secret' }, { appleKeys: [publicKey], appleAuthorization: async path => {
        if (path.endsWith('/revoke')) return new Response(null, { status: 200 });
        tokens++; entered(); await gate;
        return Response.json({ refresh_token: 'once-token', id_token: await proof(attempt) });
    } });
    try {
        const user = await enrolled(runtime);
        attempt = await challenge(runtime, user.deviceID);
        const pending = call(runtime, '/api/auth/account', { challengeID: attempt.challengeID,
            identityToken: await proof(attempt), authorizationCode: 'code' }, user.accessToken, 'DELETE');
        await waiting;
        const other = await challenge(runtime, user.deviceID);
        assert.equal((await call(runtime, '/api/auth/account', { challengeID: other.challengeID,
            identityToken: await proof(other), authorizationCode: 'second-code' }, user.accessToken, 'DELETE')).status, 503);
        assert.equal((await signIn(runtime, await challenge(runtime))).status, 409);
        assert.equal((await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE')).status, 503);
        release(); assert.equal((await pending).status, 200); assert.equal(tokens, 1);
    } finally { release(); await runtime.dispose(); }
});

test('pending Apple revocation outlives receipt expiry and retries remain bounded after exhaustion', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-apple-retry-limit-'));
    let attempt, revocations = 0, user;
    const config = { ...options, APPLE_CLIENT_SECRET: 'test-client-secret' };
    const appleAuthorization = async path => {
        if (path.endsWith('/token')) return Response.json({ refresh_token: 'pending-token', id_token: await proof(attempt) });
        revocations++; return new Response(null, { status: 503 });
    };
    let runtime = await makeRuntime(config, { storageDirectory, appleKeys: [publicKey], appleAuthorization });
    try {
        user = await enrolled(runtime); attempt = await challenge(runtime, user.deviceID);
        assert.equal((await call(runtime, '/api/auth/account', { challengeID: attempt.challengeID,
            identityToken: await proof(attempt), authorizationCode: 'code' }, user.accessToken, 'DELETE')).status, 200);
        for (const offset of [61000, 362000, 2163000, 9364000, 30965000, 86401000]) {
            await runtime.dispose();
            runtime = await makeRuntime(config, { storageDirectory, appleKeys: [publicKey], appleAuthorization, clockOffsetMs: offset });
            const result = await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE');
            assert.equal(result.status, 200); assert.equal((await result.json()).appleRevocationPending, true);
            const before = revocations;
            for (let n = 0; n < 3; n++) await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE');
            assert.equal(revocations, before, 'Manual retries cannot bypass the minimum interval');
        }
        assert.equal(revocations, 7);
        assert.equal((await call(runtime, '/api/auth/session', undefined, user.accessToken, 'GET')).status, 401);
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

async function recoveryProof(attempt, changes = {}) {
    return proof(attempt, { iat: Math.floor(attempt.issuedAt / 1000), exp: Math.floor(attempt.expiresAt / 1000), ...changes });
}
async function recoveryBody(attempt, userID, changes = {}) {
    return { challengeID: attempt.challengeID, identityToken: await recoveryProof(attempt, changes),
        authorizationCode: 'recovery-code', expectedUserID: userID };
}

test('deletion recovery authorizes revoked credentials only with same Apple subject and target', async () => {
    let attempt, exchanges = 0;
    const runtime = await makeRuntime({ ...options, APPLE_CLIENT_SECRET: 'fixture' }, { appleKeys: [publicKey], appleAuthorization: async path => {
        if (path.endsWith('/revoke')) return new Response(null, { status: 200 });
        exchanges++; return Response.json({ refresh_token: 'recovered', id_token: await recoveryProof(attempt) });
    } });
    try {
        const user = await enrolled(runtime);
        assert.equal((await call(runtime, '/api/auth/session', undefined, user.accessToken, 'DELETE')).status, 200);
        assert.equal((await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE')).status, 401);
        attempt = await challenge(runtime, user.deviceID);
        assert.equal((await call(runtime, '/api/auth/account', await recoveryBody(attempt, user.userID, { sub: 'another-person' }), user.accessToken, 'DELETE')).status, 401);
        assert.equal(exchanges, 0);
        const wrongDevice = await challenge(runtime);
        assert.equal((await call(runtime, '/api/auth/account', await recoveryBody(wrongDevice, user.userID), user.accessToken, 'DELETE')).status, 401);
        attempt = await challenge(runtime, user.deviceID);
        const missingTarget = await recoveryBody(attempt, user.userID); delete missingTarget.expectedUserID;
        assert.equal((await call(runtime, '/api/auth/account', missingTarget, user.accessToken, 'DELETE')).status, 401);
        assert.equal((await call(runtime, '/api/auth/account', await recoveryBody(attempt, '../other'), user.accessToken, 'DELETE')).status, 400);
        const body = await recoveryBody(attempt, user.userID);
        const response = await call(runtime, '/api/auth/account', body, user.accessToken, 'DELETE');
        assert.equal(response.status, 200);
        assert.deepEqual(await response.json(), { deleted: true, appleAuthorizationRevoked: true });
        assert.equal((await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE')).status, 200);
        assert.equal(exchanges, 1);
    } finally { await runtime.dispose(); }
});

test('deletion recovery survives credential expiry and later receipt expiry without registering an account', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-deletion-recovery-'));
    let attempt, exchanges = 0;
    const config = { ...options, APPLE_CLIENT_SECRET: 'fixture' };
    const provider = { storageDirectory, appleKeys: [publicKey], appleAuthorization: async path => {
        if (path.endsWith('/revoke')) return new Response(null, { status: 200 });
        exchanges++; return Response.json({ refresh_token: 'recovered', id_token: await recoveryProof(attempt) });
    } };
    let runtime = await makeRuntime(config, provider);
    try {
        const user = await enrolled(runtime);
        for (const days of [31, 33]) {
            await runtime.dispose(); runtime = await makeRuntime(config, { ...provider, clockOffsetMs: days * 86400000 });
            assert.equal((await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE')).status, 401);
            attempt = await challenge(runtime, user.deviceID);
            const result = await call(runtime, '/api/auth/account', await recoveryBody(attempt, user.userID), user.accessToken, 'DELETE');
            assert.equal(result.status, 200);
            assert.deepEqual(await result.json(), { deleted: true, appleAuthorizationRevoked: true });
            assert.equal((await call(runtime, '/api/auth/session', undefined, user.accessToken, 'GET')).status, 401);
        }
        assert.equal(exchanges, 2);
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('deletion recovery preserves a newer public account and never cancels its Apple grant', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-deletion-newer-'));
    let exchanges = 0;
    const config = { ...options, APPLE_CLIENT_SECRET: 'fixture' };
    const provider = { storageDirectory, appleKeys: [publicKey], appleAuthorization: async () => { exchanges++; return new Response(null, { status: 500 }); } };
    let runtime = await makeRuntime(config, provider);
    try {
        const user = await enrolled(runtime);
        await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE');
        await runtime.dispose(); runtime = await makeRuntime(config, { ...provider, clockOffsetMs: 2 * 86400000 });
        const registration = await challenge(runtime);
        const newer = await (await call(runtime, '/api/auth/apple/session', { challengeID: registration.challengeID, identityToken: await recoveryProof(registration) })).json();
        assert.notEqual(newer.userID, user.userID);
        const attempt = await challenge(runtime, user.deviceID);
        const result = await call(runtime, '/api/auth/account', await recoveryBody(attempt, user.userID), user.accessToken, 'DELETE');
        assert.equal(result.status, 200);
        assert.deepEqual(await result.json(), { deleted: true, appleAuthorizationRevoked: false, newerAccountPreserved: true });
        assert.equal(exchanges, 0);
        assert.equal((await call(runtime, '/api/auth/session', undefined, newer.accessToken, 'GET')).status, 200);
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('deletion recovery lets another authenticated owner device observe pending revocation without a new grant', async () => {
    let attempt, exchanges = 0;
    const runtime = await makeRuntime({ ...options, APPLE_CLIENT_SECRET: 'fixture' }, { appleKeys: [publicKey], appleAuthorization: async path => {
        if (path.endsWith('/revoke')) return new Response(null, { status: 503 });
        exchanges++; return Response.json({ refresh_token: 'pending', id_token: await recoveryProof(attempt) });
    } });
    try {
        const one = await enrolled(runtime), two = await enrolled(runtime);
        attempt = await challenge(runtime, one.deviceID);
        assert.equal((await call(runtime, '/api/auth/account', await recoveryBody(attempt, one.userID), one.accessToken, 'DELETE')).status, 200);
        const other = await challenge(runtime, two.deviceID);
        const response = await call(runtime, '/api/auth/account', await recoveryBody(other, two.userID), two.accessToken, 'DELETE');
        assert.equal(response.status, 200);
        assert.equal((await response.json()).appleRevocationPending, true);
        for (const user of [one, two]) assert.equal((await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE')).status, 200);
        assert.equal(exchanges, 1);
    } finally { await runtime.dispose(); }
});

test('account deletion media cleanup stops only its owner and releases the account slot', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    let removedSocket, otherSocket;
    try {
        const user = await enrolled(runtime), other = await enrolled(runtime, 'another-caller');
        const join = async (credential, id) => (await call(runtime, `/api/rooms/${room}/join`, { participantId: id, offer }, credential.accessToken)).json();
        const a = await join(user, 'deleted-peer'), b = await join(other, 'remaining-peer');
        for (const [credential, session] of [[user, a], [other, b]]) {
            await call(runtime, `/api/rooms/${room}/sessions/${session.sessionId}/publish`, {}, credential.accessToken);
            const url = new URL(`/api/rooms/${room}/sessions/${session.sessionId}/signal`, await runtime.ready);
            url.protocol = 'ws:';
            // workerd can leave TCP half-open after sending Close. Bound the standard
            // client handshake wait; the assertions below still require its real Close frame.
            const socket = new WebSocket(url, { closeTimeout: 250, headers: { Authorization: `Bearer ${credential.accessToken}` } });
            await new Promise((resolve, reject) => { socket.once('open', resolve); socket.once('error', reject); });
            if (credential === user) removedSocket = socket; else otherSocket = socket;
        }
        const closed = new Promise(resolve => removedSocket.addEventListener('close', resolve, { once: true }));
        const result = await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE');
        assert.equal(result.status, 200); assert.equal((await result.json()).mediaCleanupPending, undefined);
        assert.ok(provider.requests.some(r => r.url.endsWith(`/sessions/${a.sessionId}/datachannels/close`)), 'Deleted media was not closed');
        let timer;
        const event = await Promise.race([closed, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Deleted signaling stayed open')), 3000); })]).finally(() => clearTimeout(timer));
        assert.equal(event.code, 1000);
        assert.equal(event.reason, 'Account deleted');
        assert.equal(otherSocket.readyState, 1);
        assert.equal((await call(runtime, `/api/rooms/${room}/sessions/${b.sessionId}/renew`, {}, other.accessToken)).status, 200);
        const fresh = await enrolled(runtime);
        assert.equal((await call(runtime, `/api/rooms/${'d'.repeat(64)}/join`, { participantId: 'new-account', offer }, fresh.accessToken)).status, 200);
        assert.ok(provider.requests.some(r => r.url.endsWith(`/sessions/${a.sessionId}/datachannels/close`)));
        assert.ok(!provider.requests.some(r => r.url.endsWith(`/sessions/${b.sessionId}/datachannels/close`)));
    } finally { removedSocket?.close(); otherSocket?.close(); await runtime.dispose(); }
});

test('account deletion media cleanup retains failed TURN revocation across restart', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-delete-media-'));
    const config = { ...options, TURN_ENABLED: 'true', CLOUDFLARE_TURN_KEY_ID: 'test-turn', CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret' };
    let runtime = await makeRuntime(config, { storageDirectory, appleKeys: [publicKey] });
    try {
        const user = await enrolled(runtime);
        const ice = await call(runtime, `/api/rooms/${room}/ice/orphan`, { leaseID: 'delete-ice' }, user.accessToken);
        assert.equal(ice.status, 200);
        provider.revokeFails = true;
        const response = await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE');
        assert.equal(response.status, 200); assert.equal((await response.json()).mediaCleanupPending, true);
        assert.equal((await signIn(runtime, await challenge(runtime))).status, 409);
        await runtime.dispose(); provider.revokeFails = false;
        runtime = await makeRuntime(config, { storageDirectory, appleKeys: [publicKey], clockOffsetMs: 61000 });
        const retried = await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE');
        assert.equal(retried.status, 200); assert.equal((await retried.json()).mediaCleanupPending, undefined);
        assert.ok(provider.requests.some(r => r.url.includes('/credentials/') && r.url.endsWith('/revoke')));
    } finally { provider.revokeFails = false; await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});


test('account deletion collects a join already waiting for the SFU response', { timeout: 15000 }, async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    let entered, release;
    const started = new Promise(resolve => { entered = resolve; });
    const gate = new Promise(resolve => { release = resolve; });
    provider.onEstablish = async () => { entered(); await gate; };
    try {
        const user = await enrolled(runtime);
        const joining = call(runtime, `/api/rooms/${room}/join`, { participantId: 'joining-peer', offer }, user.accessToken);
        await started;
        const deleting = call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE');
        const deadline = Date.now() + 3000;
        let retired = false;
        while (Date.now() < deadline) {
            if ((await call(runtime, '/api/auth/session', undefined, user.accessToken, 'GET')).status === 401) { retired = true; break; }
            await new Promise(resolve => setTimeout(resolve, 10));
        }
        release();
        assert.ok(retired, 'Credentials must retire while provider join is pending');
        const joined = await joining;
        assert.equal(joined.status, 200);
        const session = await joined.json();
        const deleted = await deleting;
        assert.equal(deleted.status, 200);
        assert.equal((await deleted.json()).mediaCleanupPending, undefined);
        assert.ok(provider.requests.some(request => request.url.endsWith(`/sessions/${session.sessionId}/datachannels/close`)));
        assert.equal((await call(runtime, `/api/rooms/${room}/sessions/${session.sessionId}/renew`, {}, user.accessToken)).status, 401);
        const fresh = await enrolled(runtime);
        assert.equal((await call(runtime, `/api/rooms/${room}/join`, { participantId: 'fresh-peer', offer }, fresh.accessToken)).status, 200);
    } finally { release(); delete provider.onEstablish; await runtime.dispose(); }
});
