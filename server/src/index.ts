import { SignalingRoom } from './SignalingRoom'
import { UsageGuard } from './UsageGuard'
import { Env, json } from './types'
import { accountRequest, authenticateDevice } from './AppleAccount'
export { SignalingRoom, UsageGuard }
export { AppleAuthAttempt, UserAccount } from './AppleAccount'

export default {
    async fetch(request: Request, env: Env): Promise<Response> {
        const url = new URL(request.url)
        if (url.pathname === '/health' && request.method === 'GET') return json({ service: 'RideIntercom SFU', protocol: 1 })
        if (url.pathname.startsWith('/api/auth/')) return accountRequest(request, env)
        // Every billable operation is behind a per-device credential. No shared application secret in clients.
        const authorization = request.headers.get('Authorization') ?? ''
        if (!authorization.startsWith('Bearer ') || authorization.length > 512) return json({ error: 'Unauthorized' }, 401)
        let device
        try { device = await authenticateDevice(authorization.slice(7), env) }
        catch { return json({ error: 'Account service unavailable' }, 503) }
        const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(authorization.slice(7)))
        const hash = Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, '0')).join('')
        let owner: string | undefined
        if (device) owner = `${device.userID}:${device.deviceID}`
        else if (!authorization.slice(7).startsWith('ri1.')) {
            try { owner = JSON.parse(env.CLIENT_TOKENS_JSON || '{}')[hash] } catch { /* fail closed */ }
        }
        if (typeof owner !== 'string' || !owner) return json({ error: 'Unauthorized' }, 401)
        if (env.SERVICE_ENABLED !== 'true') return json({ error: 'Service paused' }, 503)
        if (!env.CLOUDFLARE_SFU_APP_ID || !env.CLOUDFLARE_SFU_APP_SECRET) return json({ error: 'SFU is not configured' }, 503)
        const headers = new Headers(request.headers)
        headers.delete('Authorization'); headers.set('X-Owner', owner)
        headers.delete('X-User'); if (device) headers.set('X-User', device.accountID)
        if (url.pathname === '/api/status' && request.method === 'GET') {
            return env.USAGE_GUARD.get(env.USAGE_GUARD.idFromName('global')).fetch(new Request('https://internal/status'))
        }
        const match = url.pathname.match(/^\/api\/rooms\/([a-f0-9]{64})\/(ice\/[a-zA-Z0-9_-]{1,80}|join|sessions\/[^/]+(?:\/(?:pull|publish|renew|signal))?)$/)
        if (!match) return json({ error: 'Invalid route or room capability' }, 400)
        return env.SIGNALING_ROOM.get(env.SIGNALING_ROOM.idFromName(match[1])).fetch(new Request(request, { headers }))
    }
}
