import { Env, Member, audioDescription, json, limit, readJSON, sfu } from './types'
export class SignalingRoom {
    constructor(private state: DurableObjectState, private env: Env) {}
    private usage(path: string, body: unknown) {
        return this.env.USAGE_GUARD.get(this.env.USAGE_GUARD.idFromName('global')).fetch(new Request(`https://internal/${path}`, { method: 'POST', body: JSON.stringify(body) }))
    }
    private async members(): Promise<Member[]> { return [...(await this.state.storage.list<Member>({ prefix: 'member:' })).values()] }
    private lease(m: Member) { return { sessionId: m.sessionId, expiresAt: m.expiresAt, renewAfterSeconds: limit(this.env.LEASE_SECONDS, 600, 3600) / 2 } }
    async fetch(request: Request): Promise<Response> {
        return this.state.blockConcurrencyWhile(async () => {
            try { return await this.handle(request) }
            catch (e) { const invalid = e instanceof Error && e.message === 'body'; return json({ error: invalid ? 'Invalid body' : 'SFU operation failed' }, invalid ? 400 : 502) }
        })
    }
    private async handle(request: Request): Promise<Response> {
        const url = new URL(request.url), owner = request.headers.get('X-Owner')!
        const members = await this.members()
        if (url.pathname.endsWith('/join') && request.method === 'POST') {
            const b = await readJSON(request)
            if (!/^[a-zA-Z0-9_-]{1,80}$/.test(b.participantId ?? '') || typeof b.displayName !== 'string' || b.displayName.length > 80
                || !audioDescription(b.offer, 'offer') || b.offer.sdp.split(/\r?\n/).filter((l: string) => l.startsWith('m=')).length !== 1) return json({ error: 'One Opus audio track is required' }, 400)
            const mid = b.offer.sdp.match(/(?:^|\n)a=mid:([^\r\n]+)/)?.[1]
            if (!mid) return json({ error: 'Missing audio mid' }, 400)
            if (members.some(m => m.id === b.participantId)) return json({ error: 'Participant already connected' }, 409)
            if (members.length >= limit(this.env.MAX_ROOM_PARTICIPANTS, 8, 8)) return json({ error: 'Room is full' }, 429)
            const leaseID = `${this.state.id}:${b.participantId}`
            const reservation = await this.usage('reserve', { id: leaseID, owner })
            if (!reservation.ok) return reservation
            const { expiresAt } = await reservation.json() as { expiresAt: number }
            let member: Member | undefined
            try {
                const created = await sfu(this.env, '/sessions/new')
                if (typeof created.sessionId !== 'string') throw new Error('upstream')
                member = { id: b.participantId, displayName: b.displayName, owner, sessionId: created.sessionId, expiresAt, mids: [], subscriptions: [], pendingAnswer: false }
                // Persist before publishing; a lost upstream response must still be cleaned up.
                await this.state.storage.put(`member:${member.sessionId}`, member)
                await this.scheduleExpiry()
                const result = await sfu(this.env, `/sessions/${member.sessionId}/tracks/new`, {
                    sessionDescription: b.offer, tracks: [{ location: 'local', mid, trackName: 'voice' }]
                })
                if (result.sessionDescription?.type !== 'answer') throw new Error('upstream')
                member.mids = (result.tracks ?? []).map((t: any) => t.mid).filter((v: any) => typeof v === 'string')
                if (!member.mids.length) throw new Error('upstream')
                await this.state.storage.put(`member:${member.sessionId}`, member)
                await this.broadcastPeers()
                return json({ ...this.lease(member), sessionDescription: result.sessionDescription })
            } catch (e) {
                if (member) { member.expiresAt = 0; await this.state.storage.put(`member:${member.sessionId}`, member); await this.state.storage.setAlarm(Date.now() + 1000) }
                await this.usage('release', { id: leaseID }); throw e
            }
        }
        const match = url.pathname.match(/\/sessions\/([^/]+)(?:\/(\w+))?$/)
        const member = members.find(m => m.sessionId === match?.[1])
        if (!member) return json({ error: 'Session not found' }, 404)
        if (member.owner !== owner) return json({ error: 'Forbidden' }, 403)
        if (member.expiresAt <= Date.now()) return json({ error: 'Lease expired' }, 410)
        const action = match?.[2]
        if (!action && request.method === 'DELETE') { await this.close(member); await this.broadcastPeers(); return json({}) }
        if (action === 'signal' && request.headers.get('Upgrade')?.toLowerCase() === 'websocket') {
            if (this.state.getWebSockets(member.sessionId).length) return json({ error: 'Signaling already connected' }, 409)
            const pair = new WebSocketPair(); this.state.acceptWebSocket(pair[1], [member.sessionId])
            pair[1].serializeAttachment({ count: 0, minute: 0 }); await this.broadcastPeers()
            return new Response(null, { status: 101, webSocket: pair[0] })
        }
        if (action === 'renew' && request.method === 'POST') {
            const r = await this.usage('reserve', { id: `${this.state.id}:${member.id}`, owner })
            if (!r.ok) return r
            member.expiresAt = (await r.json() as { expiresAt: number }).expiresAt
            await this.state.storage.put(`member:${member.sessionId}`, member); await this.scheduleExpiry(); return json(this.lease(member))
        }
        if (action === 'pull' && request.method === 'POST') {
            if (member.pendingAnswer) return json({ error: 'Answer required' }, 409)
            const b = await readJSON(request)
            if (!Array.isArray(b.peerIds) || b.peerIds.length > 7 || b.peerIds.some((id: unknown) => typeof id !== 'string')) return json({ error: 'Invalid peers' }, 400)
            const peers = members.filter(m => m.id !== member.id && b.peerIds.includes(m.id) && m.mids.length && m.expiresAt > Date.now())
            if (new Set(b.peerIds).size !== peers.length) return json({ error: 'Peer not in room' }, 403)
            const fresh = peers.filter(p => !member.subscriptions.includes(p.sessionId))
            if (!fresh.length) return json({ tracks: [] })
            const r = await sfu(this.env, `/sessions/${member.sessionId}/tracks/new`, { tracks: fresh.map(p => ({ location: 'remote', sessionId: p.sessionId, trackName: 'voice' })) })
            member.pendingAnswer = !!r.requiresImmediateRenegotiation
            member.subscriptions.push(...fresh.map(p => p.sessionId))
            member.mids.push(...(r.tracks ?? []).map((t: any) => t.mid).filter((v: any) => typeof v === 'string'))
            await this.state.storage.put(`member:${member.sessionId}`, member); return json(r)
        }
        if (action === 'answer' && request.method === 'PUT') {
            const b = await readJSON(request)
            if (!member.pendingAnswer || !audioDescription(b.sessionDescription, 'answer')) return json({ error: 'Invalid answer' }, 400)
            const r = await sfu(this.env, `/sessions/${member.sessionId}/renegotiate`, { sessionDescription: b.sessionDescription }, 'PUT')
            member.pendingAnswer = false; await this.state.storage.put(`member:${member.sessionId}`, member); return json(r)
        }
        return json({ error: 'Not found' }, 404)
    }
    async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
        const [id] = this.state.getTags(ws), member = await this.state.storage.get<Member>(`member:${id}`)
        if (!member || member.expiresAt <= Date.now() || this.env.SERVICE_ENABLED !== 'true') { ws.close(1008, 'Session expired'); return }
        const rate = ws.deserializeAttachment() as { minute: number; count: number }, minute = Math.floor(Date.now() / 60000)
        if (rate.minute !== minute) { rate.minute = minute; rate.count = 0 }
        rate.count++; ws.serializeAttachment(rate)
        if (typeof message !== 'string' || new TextEncoder().encode(message).length > 32768 || rate.count > 600) { ws.close(1008, 'Message limit'); return }
        let d: any
        try { d = JSON.parse(message) } catch { ws.close(1008, 'Invalid message'); return }
        if (d.type !== 'appData' || typeof d.namespace !== 'string' || d.namespace.length > 128 || typeof d.payload !== 'string') { ws.close(1008, 'Invalid message'); return }
        const result = JSON.stringify({ type: 'appData', from: member.id, namespace: d.namespace, payload: d.payload })
        for (const socket of this.state.getWebSockets()) if (socket !== ws) { try { socket.send(result) } catch { /* closed */ } }
    }
    webSocketClose(ws: WebSocket): void { try { ws.close(1000, 'Closed') } catch { /* closed */ } }
    webSocketError(ws: WebSocket): void { this.webSocketClose(ws) }
    private async broadcastPeers() {
        const peers = (await this.members()).filter(m => m.mids.length && m.expiresAt > Date.now()).map(m => ({ id: m.id, displayName: m.displayName }))
        for (const ws of this.state.getWebSockets()) { try { ws.send(JSON.stringify({ type: 'peers', peers })) } catch { /* closed */ } }
    }
    private async close(member: Member) {
        let mids = member.mids
        try { const status = await sfu(this.env, `/sessions/${member.sessionId}`, undefined, 'GET'); mids = (status.tracks ?? []).map((t: any) => t.mid).filter((v: any) => typeof v === 'string') }
        catch (e) {
            if (e instanceof Error && e.message === 'session-gone') mids = []
            else if (!mids.length) throw e
        }
        if (mids.length) {
            try { await sfu(this.env, `/sessions/${member.sessionId}/tracks/close`, { tracks: [...new Set(mids)].map(mid => ({ mid })), force: true }, 'PUT') }
            catch (e) { if (!(e instanceof Error && e.message === 'session-gone')) throw e }
        }
        await this.state.storage.delete(`member:${member.sessionId}`)
        await this.usage('release', { id: `${this.state.id}:${member.id}` })
        for (const ws of this.state.getWebSockets(member.sessionId)) { try { ws.close(1000, 'Session ended') } catch { /* closed */ } }
    }
    private async scheduleExpiry() {
        const members = await this.members()
        if (members.length) await this.state.storage.setAlarm(Math.max(Date.now() + 1000, Math.min(...members.map(m => m.expiresAt))))
        else await this.state.storage.deleteAlarm()
    }
    async alarm(): Promise<void> {
        await this.state.blockConcurrencyWhile(async () => {
        const expired = (await this.members()).filter(m => m.expiresAt <= Date.now() || this.env.SERVICE_ENABLED !== 'true')
        // A room has at most eight members. Parallel cleanup keeps two 8s upstream
        // deadlines within blockConcurrencyWhile's 30s limit, even during an outage.
        await Promise.all(expired.map(async m => {
            try { await this.close(m) } catch { /* Keep cleanup record and retry. */ }
        }))
        await this.broadcastPeers()
        const remaining = await this.members()
        if (remaining.some(m => m.expiresAt <= Date.now())) await this.state.storage.setAlarm(Date.now() + 30000)
        else await this.scheduleExpiry()
        })
    }
}
