import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, statSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { issueDevice } from './issue-device.mjs';
test('device credential is random, private, individually registered and never overwritten', () => {
    const dir = mkdtempSync(join(tmpdir(), 'ride-devices-'));
    try {
        const first = issueDevice('https://worker.test', 'phone', dir);
        const second = issueDevice('https://worker.test', 'mac', dir);
        const a = JSON.parse(readFileSync(first.devicePath)), b = JSON.parse(readFileSync(second.devicePath));
        assert.notEqual(a.accessToken, b.accessToken);
        assert.equal(Buffer.from(a.accessToken, 'base64url').length, 32);
        assert.equal(statSync(first.devicePath).mode & 0o777, 0o600);
        const registry = JSON.parse(readFileSync(first.registryPath));
        assert.equal(registry[createHash('sha256').update(a.accessToken).digest('hex')], 'phone');
        assert.throws(() => issueDevice('https://worker.test', 'phone', dir));
        assert.throws(() => issueDevice('http://worker.test', 'other', dir));
    } finally { rmSync(dir, { recursive: true }); }
});
