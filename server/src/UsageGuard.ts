import { Env, json, limit, readJSON } from './types'
interface Usage { month: string; reservedParticipantSeconds: number; active: Record<string, number>; day: string; starts: Record<string, number> }
export class UsageGuard {
    constructor(private state: DurableObjectState, private env: Env) {}
    async fetch(request: Request): Promise<Response> {
        return this.state.blockConcurrencyWhile(async () => {
            const now = Date.now(), date = new Date(now).toISOString()
            const stored = await this.state.storage.get<Usage>('usage')
            const usage: Usage = stored ?? { month: date.slice(0, 7), reservedParticipantSeconds: 0, active: {}, day: date.slice(0, 10), starts: {} }
            if (usage.month !== date.slice(0, 7)) { usage.month = date.slice(0, 7); usage.reservedParticipantSeconds = 0 }
            if (usage.day !== date.slice(0, 10)) { usage.day = date.slice(0, 10); usage.starts = {} }
            for (const [id, expiry] of Object.entries(usage.active)) if (expiry <= now) delete usage.active[id]
            if (new URL(request.url).pathname === '/status') return json({ month: usage.month, reservedParticipantSeconds: usage.reservedParticipantSeconds,
                monthlyParticipantSeconds: limit(this.env.MONTHLY_PARTICIPANT_SECONDS, 1000000, 100000000), activeSessions: Object.keys(usage.active).length })
            const body = await readJSON(request)
            if (new URL(request.url).pathname === '/release') { delete usage.active[body.id]; await this.state.storage.put('usage', usage); return json({}) }
            const starts = Object.hasOwn(usage.starts, body.owner) && typeof usage.starts[body.owner] === 'number'
                ? usage.starts[body.owner] : 0
            const seconds = limit(this.env.LEASE_SECONDS, 600, 3600)
            // Renewals before the halfway point are idempotent and do not reserve another lease.
            if ((usage.active[body.id] ?? 0) > now + seconds * 500) return json({ expiresAt: usage.active[body.id] })
            if (!usage.active[body.id] && (Object.keys(usage.active).length >= limit(this.env.MAX_ACTIVE_SESSIONS, 32, 512)
                || starts >= 100)) return json({ error: 'Connection quota reached' }, 429)
            if (usage.reservedParticipantSeconds + seconds > limit(this.env.MONTHLY_PARTICIPANT_SECONDS, 1000000, 100000000)) return json({ error: 'Monthly budget reached' }, 429)
            if (!usage.active[body.id]) Object.defineProperty(usage.starts, body.owner, { value: starts + 1, enumerable: true, writable: true, configurable: true })
            // Reserve the full lease before contacting SFU. Failure/retry never refunds this reservation.
            usage.reservedParticipantSeconds += seconds
            usage.active[body.id] = Math.max(now, usage.active[body.id] ?? 0) + seconds * 1000
            await this.state.storage.put('usage', usage)
            return json({ expiresAt: usage.active[body.id] })
        })
    }
}
