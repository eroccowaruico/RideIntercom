import { SignalingRoom } from './SignalingRoom'
import type { Env, SessionResponse, IceServer } from './types'

export { SignalingRoom }

export default {
    async fetch(request: Request, env: Env): Promise<Response> {
        const url = new URL(request.url)

        if (url.pathname === '/api/sessions' && request.method === 'POST') {
            return handleCreateSession(request, env)
        }

        const signalingMatch = url.pathname.match(/^\/api\/rooms\/([^/]+)\/signal$/)
        if (signalingMatch && request.headers.get('Upgrade') === 'websocket') {
            return handleSignaling(request, env, signalingMatch[1])
        }

        return new Response('Not Found', { status: 404 })
    }
}

async function handleCreateSession(request: Request, env: Env): Promise<Response> {
    let body: unknown
    try {
        body = await request.json()
    } catch {
        return json({ error: 'Invalid JSON' }, 400)
    }

    if (typeof body !== 'object' || body === null || !('roomId' in body) || !('participantId' in body)
        || typeof body.roomId !== 'string' || !body.roomId.trim()
        || typeof body.participantId !== 'string' || !body.participantId.trim()) {
        return json({ error: 'roomId and participantId are required' }, 400)
    }

    const { roomId } = body

    // Cloudflare Calls: create session
    const callsRes = await fetch(
        `https://rtc.live.cloudflare.com/v1/apps/${env.CLOUDFLARE_SFU_APP_ID}/sessions/new`,
        {
            method: 'POST',
            headers: { Authorization: `Bearer ${env.CLOUDFLARE_SFU_APP_SECRET}` }
        }
    )
    if (!callsRes.ok) {
        const text = await callsRes.text()
        console.error('Cloudflare Calls error:', callsRes.status, text)
        return json({ error: 'Failed to create Cloudflare Calls session' }, 502)
    }
    const { sessionId } = await callsRes.json() as { sessionId: string }

    // Cloudflare TURN: generate credentials (24h TTL)
    let iceServers: IceServer[] = []
    const turnRes = await fetch(
        `https://rtc.live.cloudflare.com/v1/turn/keys/${env.CLOUDFLARE_TURN_KEY_ID}/credentials/generate`,
        {
            method: 'POST',
            headers: {
                Authorization: `Bearer ${env.CLOUDFLARE_TURN_API_TOKEN}`,
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({ ttl: 86400 })
        }
    )
    if (turnRes.ok) {
        const turnData = await turnRes.json() as { iceServers: IceServer[] }
        iceServers = turnData.iceServers ?? []
    } else {
        console.warn('TURN credentials unavailable:', turnRes.status)
    }

    const { host } = new URL(request.url)
    const response: SessionResponse = {
        sessionId,
        participantToken: sessionId,
        sfuEndpoint: `https://rtc.live.cloudflare.com/v1/apps/${env.CLOUDFLARE_SFU_APP_ID}`,
        iceServers,
        signalingUrl: `wss://${host}/api/rooms/${roomId}/signal`
    }
    return json(response)
}

async function handleSignaling(request: Request, env: Env, roomId: string): Promise<Response> {
    const id = env.SIGNALING_ROOM.idFromName(roomId)
    const stub = env.SIGNALING_ROOM.get(id)
    return stub.fetch(request)
}

function json(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: { 'Content-Type': 'application/json' }
    })
}
