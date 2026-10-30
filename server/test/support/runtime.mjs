import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { Miniflare, Response } from 'miniflare';

export const token = 'test-device-token-with-at-least-32-characters';
export const hash = createHash('sha256').update(token).digest('hex');
export const room = 'a'.repeat(64);
export const offer = { type: 'offer', sdp: 'v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=mid:0\r\na=sctp-port:5000\r\n' };
export const provider = { requests: [], serial: 0, upstreamFails: false, upstreamGone: false };
export async function makeRuntime(overrides = {}, { storageDirectory, appleKeys = [], clockOffsetMs = 0, enrollmentLimits = true } = {}) {
    const source = clockOffsetMs ? { script: `const systemNow = Date.now; Date.now = () => systemNow() + ${Number(clockOffsetMs)};\n` + await readFile('dist/index.js', 'utf8') }
        : { scriptPath: 'dist/index.js' };
    const instance = new Miniflare({ durableObjectsPersist: storageDirectory,
        ratelimits: enrollmentLimits ? {
            APPLE_ENROLLMENT_IP_LIMIT: { namespace_id: '1001', simple: { limit: 30, period: 60 } },
            APPLE_ENROLLMENT_GLOBAL_LIMIT: { namespace_id: '1002', simple: { limit: 300, period: 60 } }
        } : {},
        modules: true, ...source, compatibilityDate: '2024-11-01',
        durableObjects: { SIGNALING_ROOM: { className: 'SignalingRoom', useSQLite: true }, USAGE_GUARD: { className: 'UsageGuard', useSQLite: true },
            APPLE_AUTH_ATTEMPT: { className: 'AppleAuthAttempt', useSQLite: true }, USER_ACCOUNT: { className: 'UserAccount', useSQLite: true } },
        bindings: { SERVICE_ENABLED: 'true', CLIENT_TOKENS_JSON: JSON.stringify({ [hash]: 'tester' }),
            CLOUDFLARE_SFU_APP_ID: 'test-app', CLOUDFLARE_SFU_APP_SECRET: 'test-secret',
            MAX_ROOM_PARTICIPANTS: '4', MAX_ACTIVE_SESSIONS: '16', MONTHLY_PARTICIPANT_SECONDS: '36000', LEASE_SECONDS: '600', ...overrides },
        outboundService: async request => {
            if (request.url === 'https://appleid.apple.com/auth/keys') return Response.json({ keys: appleKeys });
            const text = await request.text();
            provider.requests.push({ url: request.url, method: request.method, body: text ? JSON.parse(text) : undefined });
            const isTurn = request.url.includes('/turn/keys/')
            assert.equal(request.headers.get('Authorization'), isTurn ? 'Bearer test-turn-secret' : 'Bearer test-secret');
            const url = new URL(request.url);
            assert.equal(url.hostname, 'rtc.live.cloudflare.com');
            if (provider.upstreamGone) return Response.json({}, { status: 410 });
            if (provider.upstreamFails) return Response.json({ errorCode: 'failure' }, { status: 503 });
            if (url.pathname.endsWith('/generate-ice-servers')) return Response.json({ iceServers: [
                { urls: ['stun:stun.cloudflare.com:3478'] },
                { urls: ['turn:turn.cloudflare.com:3478?transport=udp', 'turns:turn.cloudflare.com:443?transport=tcp'], username: `turn-user-${++provider.serial}`, credential: 'ephemeral-credential' }
            ] }, { status: 201 });
            if (url.pathname.endsWith('/revoke') && provider.onRevoke) await provider.onRevoke();
            if (url.pathname.endsWith('/revoke')) return provider.revokeFails ? Response.json({}, { status: 503 }) : new Response(null, { status: 204 });
            if (url.pathname.endsWith('/sessions/new')) return Response.json({ sessionId: `sfu-${++provider.serial}` }, { status: 201 });
            if (url.pathname.endsWith('/datachannels/establish') && provider.establishFails) return Response.json({}, { status: 503 });
            if (url.pathname.endsWith('/datachannels/establish')) return Response.json({ sessionDescription: { type: 'answer', sdp: 'mock-sfu-sdp' }, dataChannel: { id: 0 } });
            if (url.pathname.endsWith('/datachannels/new')) return Response.json({ dataChannels: provider.requests.at(-1).body.dataChannels.map(c => ({ ...c, id: ++provider.serial })) });
            if (url.pathname.endsWith('/datachannels/close')) return Response.json({ dataChannels: provider.requests.at(-1).body.dataChannels });
            if (url.pathname.endsWith('/tracks/update')) return Response.json({ requiresImmediateRenegotiation: false, tracks: provider.requests.at(-1).body.tracks });
            if (url.pathname.endsWith('/tracks/new')) {
                const body = provider.requests.at(-1).body;
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
