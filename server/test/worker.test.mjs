import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { Miniflare, Response } from 'miniflare';

let runtime;
let callsStatus = 200;
let turnStatus = 200;
let requests = [];

before(async () => {
    runtime = new Miniflare({
        modules: true,
        scriptPath: 'dist/index.js',
        compatibilityDate: '2024-11-01',
        durableObjects: { SIGNALING_ROOM: 'SignalingRoom' },
        bindings: {
            CLOUDFLARE_SFU_APP_ID: 'test-app', CLOUDFLARE_SFU_APP_SECRET: 'test-secret',
            CLOUDFLARE_TURN_KEY_ID: 'test-key', CLOUDFLARE_TURN_API_TOKEN: 'test-token',
        },
        outboundService: async (request) => {
            requests.push(request.url);
            assert.equal(request.method, 'POST');
            const url = new URL(request.url);
            assert.equal(url.hostname, 'rtc.live.cloudflare.com');
            if (url.pathname.endsWith('/sessions/new')) {
                assert.equal(request.headers.get('Authorization'), 'Bearer test-secret');
                return Response.json({ sessionId: 'session-test' }, { status: callsStatus });
            }
            assert.equal(url.pathname, '/v1/turn/keys/test-key/credentials/generate');
            assert.deepEqual(await request.json(), { ttl: 86400 });
            return Response.json({ iceServers: [{ urls: ['turn:example.invalid'] }] }, { status: turnStatus });
        },
    });
    await runtime.ready;
});
after(async () => { await runtime?.dispose(); });

const createSession = (body) => runtime.dispatchFetch('https://worker.test/api/sessions', { method: 'POST', body });

test('HTTP routes reject invalid input without contacting Cloudflare', async () => {
    requests = [];
    assert.equal((await runtime.dispatchFetch('https://worker.test/unknown')).status, 404);
    for (const body of ['{', '{}', 'null', '[]', '{"roomId":123,"participantId":"a"}']) {
        assert.equal((await createSession(body)).status, 400, body);
    }
    assert.equal(requests.length, 0);
});

test('session API returns credentials and URL from mocked providers', async () => {
    const response = await createSession(JSON.stringify({ roomId: 'group-a', participantId: 'a' }));
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.equal(body.sessionId, 'session-test');
    assert.equal(body.participantToken, 'session-test');
    assert.equal(body.signalingUrl, 'wss://worker.test/api/rooms/group-a/signal');
    assert.deepEqual(body.iceServers, [{ urls: ['turn:example.invalid'] }]);
});

test('Calls failure is 502 and TURN failure remains nonfatal', async () => {
    try {
        callsStatus = 503;
        assert.equal((await createSession('{"roomId":"g","participantId":"a"}')).status, 502);
        callsStatus = 200;
        turnStatus = 503;
        const response = await createSession('{"roomId":"g","participantId":"a"}');
        assert.equal(response.status, 200);
        assert.deepEqual((await response.json()).iceServers, []);
    } finally {
        callsStatus = turnStatus = 200;
    }
});

async function connect(id, room = 'room') {
    const response = await runtime.dispatchFetch(`https://worker.test/api/rooms/${room}/signal?participantId=${id}&displayName=${id}`, { headers: { Upgrade: 'websocket' } });
    assert.equal(response.status, 101);
    const socket = response.webSocket;
    const messages = [];
    socket.addEventListener('message', event => messages.push(JSON.parse(event.data)));
    socket.accept();
    async function take(type) {
        const deadline = Date.now() + 5000;
        while (Date.now() < deadline) {
            const index = messages.findIndex(message => message.type === type);
            if (index >= 0) return messages.splice(index, 1)[0];
            await new Promise(resolve => setTimeout(resolve, 10));
        }
        assert.fail(`Missing ${type}: ${JSON.stringify(messages)}`);
    }
    await take('joined');
    return { socket, take, messages };
}

test('real Durable Object WebSockets join, relay, isolate rooms, and leave', async () => {
    const a = await connect('a');
    const b = await connect('b');
    const other = await connect('other', 'different-room');
    try {
        assert.equal((await a.take('peerJoined')).peer.id, 'b');
        assert.equal((await b.take('peerJoined')).peer.id, 'a');
        for (const type of ['offer', 'answer', 'candidate']) {
            a.socket.send(JSON.stringify({ type, to: 'b', sdp: 'test-sdp', sdpMid: 'audio', sdpMLineIndex: 0, from: 'forged' }));
            assert.equal((await b.take(type)).from, 'a');
        }
        b.socket.send(JSON.stringify({ type: 'appData', to: null, namespace: 'mute', payload: 'true' }));
        assert.equal((await a.take('appData')).from, 'b');
        a.socket.send('not json');
        assert.equal((await a.take('error')).message, 'Invalid JSON');
        assert.equal(other.messages.length, 0);
        b.socket.close(1000, 'done');
        assert.equal((await a.take('peerLeft')).peerId, 'b');
    } finally {
        for (const peer of [a, b, other]) {
            if (peer.socket.readyState < 2) peer.socket.close(1000, 'cleanup');
        }
    }
});
