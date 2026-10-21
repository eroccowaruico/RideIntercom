import { test } from 'node:test';
import assert from 'node:assert/strict';
import { estimate } from './estimate-cost.mjs';
test('SFU fanout counts each receiving participant and free tier once', () => {
    const r = estimate({ users: 1000, hours: 20, roomSize: 4, wireKbps: 64 });
    assert.equal(r.minutes, 1200000); assert.equal(r.gb, 1728);
    assert.equal(r.costs.realtime, 36.4); assert.equal(r.realtimeKitAudio, 600);
    assert.equal(estimate({ users: 1000, roomSize: 8, wireKbps: 64 }).gb, 4032);
});
test('silence assumptions, paid control costs and duration sensitivity are explicit', () => {
    assert.equal(estimate({ speakingFraction: .3, wireKbps: 64 }).gb, 518.4);
    assert.ok(estimate({ activeMsPerEvent: 1000 }).costs.doDuration > 0);
    assert.equal(estimate({ users: 4, paid: false }).total, 0);
    assert.equal(estimate({ users: 4, paid: true }).total, 5);
    assert.throws(() => estimate({ roomSize: 1 }));
});

test('relay wire overhead and multiple gateway copies can exceed time pricing', () => {
    const direct = estimate({ wireKbps: 384 });
    const relay = estimate();
    assert.equal(relay.wireKbps, 512);
    assert.equal(relay.gb, 13824);
    assert.ok(direct.total < direct.realtimeKitAudio);
    assert.ok(relay.total > relay.realtimeKitAudio);
    assert.equal(estimate({ relayCopies: 2 }).gb, relay.gb * 2);
    assert.ok(estimate({ wireKbps: 1536 }).total > relay.total);
    assert.throws(() => estimate({ relayCopies: 0 }));
});
