import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { generateKeyPair, exportJWK, SignJWT } from 'jose';
import { makeRuntime, offer, room } from './support/runtime.mjs';

const keys = await generateKeyPair('RS256');
const publicKey = { ...await exportJWK(keys.publicKey), kid: 'apple-fixture', alg: 'RS256', use: 'sig' };
const audience = 'com.yowamushi-inc.RideIntercom.RideIntercom';
const options = { APPLE_AUTH_ENABLED: 'true', APPLE_CLIENT_ID: audience, CLIENT_TOKENS_JSON: '{}' };
const call = (runtime, path, body, token, method = 'POST') => runtime.dispatchFetch(`https://worker.test${path}`, {
    method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
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
        const attempt = await challenge(runtime);
        for (const claims of [{ nonce: 'wrong' }, { aud: 'another-app' }, { iss: 'https://attacker.invalid' },
            { exp: 1 }, { sub: '' }, { iat: Math.floor(Date.now() / 1000) + 3600 }, { nonce: undefined }]) {
            assert.equal((await signIn(runtime, attempt, claims)).status, 401);
        }
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
        assert.equal((await signIn(runtime, await challenge(runtime))).status, 429);
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
