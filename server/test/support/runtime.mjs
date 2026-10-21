import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { Miniflare, Response } from 'miniflare';

export const token = 'test-device-token-with-at-least-32-characters';
export const hash = createHash('sha256').update(token).digest('hex');
export const room = 'a'.repeat(64);
export const offer = { type: 'offer', sdp: 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\na=rtpmap:111 opus/48000/2\r\n' };
export const provider = { requests: [], serial: 0, upstreamFails: false, upstreamGone: false };
export async function makeRuntime(overrides = {}) {
    const instance = new Miniflare({ modules: true, scriptPath: 'dist/index.js', compatibilityDate: '2024-11-01',
        durableObjects: { SIGNALING_ROOM: { className: 'SignalingRoom', useSQLite: true }, USAGE_GUARD: { className: 'UsageGuard', useSQLite: true } },
        bindings: { SERVICE_ENABLED: 'true', CLIENT_TOKENS_JSON: JSON.stringify({ [hash]: 'tester' }),
            CLOUDFLARE_SFU_APP_ID: 'test-app', CLOUDFLARE_SFU_APP_SECRET: 'test-secret',
            MAX_ROOM_PARTICIPANTS: '4', MAX_ACTIVE_SESSIONS: '16', MONTHLY_PARTICIPANT_SECONDS: '36000', LEASE_SECONDS: '600', ...overrides },
        outboundService: async request => {
            const text = await request.text();
            provider.requests.push({ url: request.url, method: request.method, body: text ? JSON.parse(text) : undefined });
            assert.equal(request.headers.get('Authorization'), 'Bearer test-secret');
            const url = new URL(request.url);
            assert.equal(url.hostname, 'rtc.live.cloudflare.com');
            if (provider.upstreamGone) return Response.json({}, { status: 410 });
            if (provider.upstreamFails) return Response.json({ errorCode: 'failure' }, { status: 503 });
            if (url.pathname.endsWith('/sessions/new')) return Response.json({ sessionId: `sfu-${++provider.serial}` }, { status: 201 });
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
