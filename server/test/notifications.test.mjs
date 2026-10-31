import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { generateKeyPair, exportJWK, exportPKCS8, SignJWT } from 'jose';
import { makeRuntime } from './support/runtime.mjs';

const apple = await generateKeyPair('RS256');
const applePublic = { ...await exportJWK(apple.publicKey), kid: 'notification-apple-fixture', alg: 'RS256' };
const signing = await generateKeyPair('ES256', { extractable: true });
const options = { APPLE_AUTH_ENABLED: 'true', APPLE_CLIENT_ID: 'fixture-app', CLIENT_TOKENS_JSON: '{}',
    NOTIFICATIONS_ENABLED: 'true', DEVICE_IDENTITY_SIGNING_KEY: JSON.stringify(await exportJWK(signing.privateKey)),
    APNS_PRIVATE_KEY: await exportPKCS8(signing.privateKey), APNS_KEY_ID: 'fixturekey', APNS_TEAM_ID: 'fixtureteam',
    APNS_TOPIC: 'fixture-app', APNS_ENVIRONMENT: 'sandbox' };
const call = (r, path, body, token, method = 'POST') => r.dispatchFetch('https://worker.test' + path, {
    method, headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': '192.0.2.77', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
async function login(r, subject, deviceID = randomUUID()) {
    const a = await (await call(r, '/api/auth/apple/challenge', { deviceID })).json();
    const identityToken = await new SignJWT({ sub: subject, nonce: a.nonce }).setIssuer('https://appleid.apple.com')
        .setAudience('fixture-app').setIssuedAt().setExpirationTime('5m').setProtectedHeader({ alg: 'RS256', kid: applePublic.kid }).sign(apple.privateKey);
    const response = await call(r, '/api/auth/apple/session', { challengeID: a.challengeID, identityToken });
    assert.equal(response.status, 200); return response.json();
}
const register = (r, user, token = 'ab'.repeat(48)) => call(r, '/api/notifications/device', { token, environment: 'sandbox', topic: 'fixture-app' }, user.accessToken, 'PUT');
async function grant(r, receiver, sender) {
    const response = await call(r, '/api/notifications/grants', { senderUserID: sender.userID }, receiver.accessToken);
    assert.equal(response.status, 200); return response.json();
}
const send = (r, user, capability, requestID = randomUUID()) => call(r, '/api/notifications/calls', { capability, requestID }, user.accessToken);
async function setup(overrides = {}, apns = async () => Response.json({}), runtimeOptions = {}) {
    return makeRuntime({ ...options, ...overrides }, { appleKeys: [applePublic], apns, ...runtimeOptions });
}

test('notifications stay unavailable without configuration and do not disable authentication', async () => {
    const r = await setup({ NOTIFICATIONS_ENABLED: 'false' });
    try {
        const a = await login(r, 'a');
        assert.equal((await register(r, a)).status, 503);
        assert.equal((await call(r, '/api/auth/session', undefined, a.accessToken, 'GET')).status, 200);
    } finally { await r.dispose(); }
});

test('only a recipient capability authorizes a fixed alert; dedupe, read and cancel preserve ownership', async () => {
    const requests = [];
    const r = await setup({}, async request => { requests.push({ url: request.url, headers: Object.fromEntries(request.headers), body: await request.json() }); return Response.json({}); });
    try {
        const a = await login(r, 'a'), b = await login(r, 'b'), c = await login(r, 'c');
        assert.equal((await register(r, b)).status, 200);
        const g = await grant(r, b, a);
        assert.equal((await send(r, c, g.capability)).status, 403);
        assert.equal((await send(r, a, b.userID)).status, 403);
        const id = randomUUID();
        const response = await send(r, a, g.capability, id);
        assert.equal(response.status, 200); assert.equal((await response.json()).status, 'accepted');
        assert.equal((await send(r, a, g.capability, id.toUpperCase())).status, 200);
        assert.equal(requests.length, 1);
        assert.equal(requests[0].headers['apns-push-type'], 'alert');
        assert.equal(requests[0].body.requestID, id);
        assert.equal(requests[0].body.aps.alert['loc-key'], 'CALL_REQUEST_BODY');
        assert.ok(!JSON.stringify(requests).includes(g.capability));
        const path = `/api/notifications/calls/${b.userID}/${id}`;
        assert.equal((await call(r, path, undefined, c.accessToken, 'GET')).status, 404);
        assert.equal((await call(r, path, undefined, a.accessToken, 'GET')).status, 404);
        assert.equal((await call(r, path, undefined, b.accessToken, 'GET')).status, 200);
        assert.equal((await call(r, path, undefined, c.accessToken, 'DELETE')).status, 404);
        assert.equal((await call(r, path, undefined, a.accessToken, 'DELETE')).status, 200);
        assert.equal((await call(r, path, undefined, b.accessToken, 'GET')).status, 410);
        assert.equal((await send(r, a, g.capability, id.toUpperCase())).status, 200);
        assert.equal(requests.length, 1);
    } finally { await r.dispose(); }
});

test('revocation removes the active grant and old capabilities cannot be recreated by replay', async () => {
    const requests = []; const r = await setup({}, async q => { requests.push(q.url); return Response.json({}); });
    try {
        const a = await login(r, 'a'), b = await login(r, 'b'); await register(r, b);
        const g = await grant(r, b, a);
        assert.equal((await call(r, `/api/notifications/grants/${g.grantID}`, undefined, a.accessToken, 'DELETE')).status, 200);
        assert.equal((await send(r, a, g.capability)).status, 200, 'other recipient cannot revoke this grant');
        assert.equal((await call(r, `/api/notifications/grants/${g.grantID}`, undefined, b.accessToken, 'DELETE')).status, 200);
        assert.equal((await send(r, a, g.capability)).status, 403);
        const next = await grant(r, b, a); assert.notEqual(next.grantID, g.grantID);
        assert.equal((await send(r, a, g.capability)).status, 403);
        assert.equal(requests.length, 1);
    } finally { await r.dispose(); }
});

test('sign-out and credential replacement remove old destinations; deletion retires old grants', async () => {
    let count = 0; const r = await setup({}, async () => { count++; return Response.json({}); });
    try {
        const a = await login(r, 'a'), b = await login(r, 'b'); await register(r, b); const g = await grant(r, b, a);
        await call(r, '/api/auth/session', undefined, b.accessToken, 'DELETE');
        assert.equal((await send(r, a, g.capability)).status, 200); assert.equal(count, 0);
        const b2 = await login(r, 'b', b.deviceID); await register(r, b2);
        await login(r, 'b', b.deviceID);
        assert.equal((await send(r, a, g.capability)).status, 200); assert.equal(count, 0);
        const b3 = await login(r, 'b', b.deviceID); await register(r, b3);
        assert.equal((await call(r, '/api/auth/account', undefined, b3.accessToken, 'DELETE')).status, 200);
        const b4 = await login(r, 'b', b.deviceID); await register(r, b4);
        assert.notEqual(b4.userID, b.userID);
        assert.equal((await send(r, a, g.capability)).status, 403); assert.equal(count, 0);
    } finally { await r.dispose(); }
});

test('a delayed 410 cannot remove a newly registered token and token ownership prevents cross-account delivery', async () => {
    let first = true, r, b; const seen = [];
    r = await setup({}, async request => {
        seen.push(request.url);
        if (first) { first = false; assert.equal((await register(r, b, 'cd'.repeat(80))).status, 200); return Response.json({ reason: 'Unregistered', timestamp: Date.now() }, { status: 410 }); }
        return Response.json({});
    });
    try {
        const a = await login(r, 'a'); b = await login(r, 'b'); const c = await login(r, 'c');
        await register(r, b); const g = await grant(r, b, a);
        await send(r, a, g.capability); await send(r, a, g.capability);
        assert.equal(seen.length, 2); assert.ok(seen[1].endsWith('cd'.repeat(80)));
        await register(r, c, 'cd'.repeat(80)); await send(r, a, g.capability);
        assert.equal(seen.length, 2);
    } finally { await r.dispose(); }
});

test('APNs failures remain delivery failures and duplicate requests cannot amplify retries', async () => {
    let count = 0; const r = await setup({}, async () => { count++; return Response.json({ reason: count === 1 ? 'TooManyRequests' : 'ServiceUnavailable' }, { status: count === 1 ? 429 : 503 }); });
    try {
        const a = await login(r, 'a'), b = await login(r, 'b'); await register(r, b); const g = await grant(r, b, a);
        const id = randomUUID(); const first = await send(r, a, g.capability, id);
        assert.equal(first.status, 200); assert.equal((await first.json()).status, 'retry_later');
        await send(r, a, g.capability, id); assert.equal(count, 1);
        const second = await send(r, a, g.capability); assert.equal((await second.json()).status, 'retry_later'); assert.equal(count, 2);
    } finally { await r.dispose(); }
});

test('old routing and token indexes are removed on replacement, sign-out and deletion', async () => {
    const r = await setup();
    try {
        const a = await login(r, 'a'), b = await login(r, 'b');
        const { createHash } = await import('node:crypto');
        const indexes = await r.getDurableObjectNamespace('NOTIFICATION_INDEX');
        const tokenKey = value => 'token:' + createHash('sha256').update('sandbox|fixture-app|' + value).digest('hex');
        const readIndex = async key => {
            return indexes.get(indexes.idFromName(key)).current();
        };
        await register(r, b); assert.ok(await readIndex(tokenKey('ab'.repeat(48))));
        await register(r, b, 'ef'.repeat(41)); assert.equal(await readIndex(tokenKey('ab'.repeat(48))), null);
        await call(r, '/api/auth/session', undefined, b.accessToken, 'DELETE');
        assert.equal(await readIndex(tokenKey('ef'.repeat(41))), null);
        const b2 = await login(r, 'b', b.deviceID); await register(r, b2);
        const g = await grant(r, b2, a); assert.ok(g.capability);
        await call(r, '/api/auth/account', undefined, b2.accessToken, 'DELETE');
        assert.equal(await readIndex('user:' + b.userID), null);
        assert.equal(await readIndex(tokenKey('ab'.repeat(48))), null);
    } finally { await r.dispose(); }
});

test('notification registration and issuance have an account-scoped mutation budget', async () => {
    const r = await setup({}, undefined, { fixedNowMs: Date.now() });
    try {
        const a = await login(r, 'a');
        for (let i = 0; i < 60; i++) assert.equal((await register(r, a)).status, 200);
        assert.equal((await register(r, a)).status, 429);
        assert.equal((await call(r, '/api/notifications/grants', { senderUserID: 'a'.repeat(64) }, a.accessToken)).status, 429);
        assert.equal((await call(r, '/api/notifications/device', undefined, a.accessToken, 'DELETE')).status, 200);
    } finally { await r.dispose(); }
});

test('expiry, dedupe and revoked grants survive a runtime restart, including disabled-delivery cancellation', async () => {
    const { mkdtemp, rm } = await import('node:fs/promises'); const { tmpdir } = await import('node:os'); const { join } = await import('node:path');
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-notification-restart-'));
    let count = 0; const apns = async () => { count++; return Response.json({}); };
    let r = await setup({}, apns, { storageDirectory });
    try {
        const a = await login(r, 'a'), b = await login(r, 'b'); await register(r, b); const g = await grant(r, b, a);
        const id = randomUUID(); await send(r, a, g.capability, id);
        await r.dispose(); r = await setup({}, apns, { storageDirectory, clockOffsetMs: 121_000 });
        const path = `/api/notifications/calls/${b.userID}/${id}`;
        assert.equal((await call(r, path, undefined, b.accessToken, 'GET')).status, 410);
        await send(r, a, g.capability, id); assert.equal(count, 1);
        const secondID = randomUUID(); await send(r, a, g.capability, secondID); assert.equal(count, 2);
        await call(r, `/api/notifications/grants/${g.grantID}`, undefined, b.accessToken, 'DELETE');
        await r.dispose(); r = await setup({ NOTIFICATIONS_ENABLED: 'false' }, apns, { storageDirectory, clockOffsetMs: 121_000 });
        assert.equal((await call(r, `/api/notifications/calls/${b.userID}/${secondID}`, undefined, a.accessToken, 'DELETE')).status, 200);
        await r.dispose(); r = await setup({}, apns, { storageDirectory, clockOffsetMs: 122_000 });
        assert.equal((await send(r, a, g.capability)).status, 403); assert.equal(count, 2);
    } finally { await r.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('concurrent duplicate calls send once and cancellation during delivery cannot become accepted again', async () => {
    let count = 0, entered, release; const ready = new Promise(resolve => { entered = resolve; }); const gate = new Promise(resolve => { release = resolve; });
    const r = await setup({}, async () => { count++; entered(); await gate; return Response.json({}); });
    try {
        const a = await login(r, 'a'), b = await login(r, 'b'); await register(r, b); const g = await grant(r, b, a); const id = randomUUID();
        const first = send(r, a, g.capability, id); await ready;
        const duplicate = await send(r, a, g.capability, id); assert.equal((await duplicate.json()).status, 'processing');
        assert.equal((await call(r, `/api/notifications/calls/${b.userID}/${id}`, undefined, a.accessToken, 'DELETE')).status, 200);
        release(); assert.equal((await (await first).json()).status, 'cancelled'); assert.equal(count, 1);
    } finally { release(); await r.dispose(); }
});

test('recipient deletion or sender sign-out during first delivery stops all remaining device deliveries', async () => {
    for (const retire of ['recipient', 'sender']) {
        let count = 0, r, a, b;
        r = await setup({}, async () => {
            count++;
            if (count === 1) {
                const response = retire === 'recipient' ? await call(r, '/api/auth/account', undefined, b.accessToken, 'DELETE')
                    : await call(r, '/api/auth/session', undefined, a.accessToken, 'DELETE');
                assert.equal(response.status, 200);
            }
            return Response.json({});
        });
        try {
            a = await login(r, 'a'); b = await login(r, 'b'); const another = await login(r, 'b');
            await register(r, b); await register(r, another, 'de'.repeat(64)); const g = await grant(r, b, a);
            const id = randomUUID(); await send(r, a, g.capability, id); assert.equal(count, 1);
            assert.notEqual((await call(r, `/api/notifications/calls/${b.userID}/${id}`, undefined, another.accessToken, 'GET')).status, 200);
        } finally { await r.dispose(); }
    }
});

test('recipient send limit is persisted, while extra private fields and non-Apple credentials are rejected', async () => {
    let count = 0; const r = await setup({}, async () => { count++; return Response.json({}); }, { fixedNowMs: Date.now() });
    try {
        const a = await login(r, 'a'), b = await login(r, 'b'); await register(r, b); const g = await grant(r, b, a);
        assert.equal((await call(r, '/api/notifications/calls', { capability: g.capability, requestID: randomUUID(), displayName: 'PrivateHumanName' }, a.accessToken)).status, 400);
        assert.equal((await call(r, '/api/notifications/grants', { senderUserID: a.userID, groupID: randomUUID() }, b.accessToken)).status, 400);
        assert.equal((await call(r, '/api/notifications/device', { token: 'ab'.repeat(32), environment: 'production', topic: 'fixture-app' }, b.accessToken, 'PUT')).status, 400);
        assert.equal((await call(r, '/api/notifications/device', {}, 'test-device-token-with-at-least-32-characters', 'PUT')).status, 401);
        for (let i = 0; i < 20; i++) assert.equal((await send(r, a, g.capability)).status, 200);
        assert.equal((await send(r, a, g.capability)).status, 429); assert.equal(count, 20);
    } finally { await r.dispose(); }
});

test('persistent notification state never stores a capability, private names or group material', async () => {
    const { mkdtemp, readFile, readdir, rm } = await import('node:fs/promises'); const { tmpdir } = await import('node:os'); const { join } = await import('node:path');
    const { createHash } = await import('node:crypto');
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-notification-privacy-'));
    const r = await setup({}, undefined, { storageDirectory });
    try {
        const a = await login(r, 'a'), b = await login(r, 'b'); await register(r, b); const g = await grant(r, b, a);
        await send(r, a, g.capability);
        assert.equal((await call(r, '/api/notifications/grants', { senderUserID: a.userID, displayName: 'PrivateNotificationName', groupSecret: 'PrivateGroupMaterial' }, b.accessToken)).status, 400);
        const files = (await readdir(storageDirectory, { recursive: true })).filter(file => /\.sqlite(?:-wal)?$/.test(file));
        assert.ok(files.length > 0);
        const bytes = Buffer.concat(await Promise.all(files.map(file => readFile(join(storageDirectory, file)))));
        assert.ok(bytes.includes(Buffer.from(createHash('sha256').update(g.grantID).digest('hex'))), 'Inspect the persisted active grant');
        for (const secret of [g.capability, 'PrivateNotificationName', 'PrivateGroupMaterial', a.accessToken, b.accessToken]) assert.ok(!bytes.includes(Buffer.from(secret)));
    } finally { await r.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});


test('APNs provider credentials are reused between requests within their validity window', async () => {
    const tokens = []; const r = await setup({}, async request => { tokens.push(request.headers.get('authorization')); return Response.json({}); });
    try {
        const a = await login(r, 'a'), b = await login(r, 'b'); await register(r, b); const g = await grant(r, b, a);
        await send(r, a, g.capability); await send(r, a, g.capability);
        assert.equal(tokens.length, 2); assert.equal(tokens[0], tokens[1]);
    } finally { await r.dispose(); }
});

test('an older device cannot shorten the current public route, while token ownership follows the latest registration', async () => {
    const r = await setup();
    try {
        const indexes = await r.getDurableObjectNamespace('NOTIFICATION_INDEX');
        const route = indexes.get(indexes.idFromName('user:' + 'a'.repeat(64)));
        const newerExpiry = Date.now() + 120_000, olderExpiry = Date.now() + 60_000;
        const owner = { accountID: 'account-a', userID: 'a'.repeat(64) };
        await route.bind({ ...owner, expiresAt: newerExpiry });
        await route.bind({ ...owner, expiresAt: olderExpiry });
        assert.equal(await (await route.current()).expiresAt, newerExpiry);
        // The same optimization must never preserve a previous APNs-token owner.
        const token = indexes.get(indexes.idFromName('token:' + 'b'.repeat(64)));
        await token.bind({ ...owner, deviceID: 'device-a', registrationID: 'first', expiresAt: newerExpiry });
        await token.bind({ accountID: 'account-b', userID: 'b'.repeat(64), deviceID: 'device-b', registrationID: 'second', expiresAt: olderExpiry });
        const current = await token.current();
        assert.equal(await current.expiresAt, olderExpiry);
        assert.equal(await current.accountID, 'account-b');
        assert.equal(await current.registrationID, 'second');
        await route.bind({ accountID: 'account-b', userID: 'b'.repeat(64), expiresAt: olderExpiry });
        assert.equal(await (await route.current()).expiresAt, olderExpiry, 'unrelated public identity must not inherit the expiry');
    } finally { await r.dispose(); }
});
