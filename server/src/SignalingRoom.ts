import { TurnCredentials, stun } from './TurnCredentials'
import { Env, Member, dataDescription, json, limit, readJSON, sfu } from './types'
export class SignalingRoom {
    private turn: TurnCredentials
    constructor(private state: DurableObjectState, private env: Env) { this.turn = new TurnCredentials(state.storage, env) }
    private usage(path: string, body: unknown) {
        return this.env.USAGE_GUARD.get(this.env.USAGE_GUARD.idFromName('global')).fetch(new Request(`https://internal/${path}`, { method: 'POST', body: JSON.stringify(body) }))
    }
    private async members(): Promise<Member[]> { return [...(await this.state.storage.list<Member>({ prefix: 'member:' })).values()] }
    private lease(m: Member) { return { sessionId: m.sessionId, expiresAt: m.expiresAt, renewAfterSeconds: limit(this.env.LEASE_SECONDS, 600, 3600) / 2 } }
    async fetch(request: Request): Promise<Response> {
        return this.state.blockConcurrencyWhile(async () => {
            try {
                if (new URL(request.url).pathname === '/retire-account') return await this.retireAccount(await readJSON(request))
                const accountID = request.headers.get('X-User'), publicUserID = request.headers.get('X-Owner')?.split(':')[0]
                if (accountID && publicUserID) {
                    const account = this.env.USER_ACCOUNT.get(this.env.USER_ACCOUNT.idFromString(accountID))
                    if (!await account.attachRoom(publicUserID, this.state.id.toString())) return json({ error: 'Account access ended' }, 403)
                    await this.state.storage.put(`account:${publicUserID}`, accountID)
                }
                try { return await this.handle(request) }
                finally { if (accountID && publicUserID) await this.detachIfEmpty(publicUserID, accountID) }
            }
            catch (e) { const invalid = e instanceof Error && e.message === 'body'; return json({ error: invalid ? 'Invalid body' : 'SFU operation failed' }, invalid ? 400 : 502) }
        })
    }
    private async detachIfEmpty(publicUserID: string, accountID: string) {
        const prefix = publicUserID + ':'
        if ((await this.members()).some(m => m.owner.startsWith(prefix)) || (await this.turn.all()).some(ice => ice.owner.startsWith(prefix))) return
        await this.env.USER_ACCOUNT.get(this.env.USER_ACCOUNT.idFromString(accountID)).detachRoom(publicUserID, this.state.id.toString())
        await this.state.storage.delete(`account:${publicUserID}`)
    }
    private async retireAccount(body: { publicUserID: string; accountID: string }): Promise<Response> {
        if (!/^[a-f0-9]{64}$/.test(body.publicUserID) || !/^[a-f0-9]{64}$/.test(body.accountID)) return json({ error: 'Invalid account' }, 400)
        const prefix = body.publicUserID + ':'
        const members = (await this.members()).filter(m => m.owner.startsWith(prefix))
        const owned = new Set(members.map(m => m.id))
        const orphans = (await this.turn.all()).filter(ice => ice.owner.startsWith(prefix) && !owned.has(ice.peer))
        // End signaling and admission before contacting external media providers.
        for (const member of members) {
            member.expiresAt = 0
            await this.state.storage.put(`member:${member.sessionId}`, member)
            for (const ws of this.state.getWebSockets(member.sessionId)) { try { ws.close(1000, 'Account deleted') } catch { /* closed */ } }
        }
        for (const ice of orphans) { ice.expiresAt = 0; await this.state.storage.put(`ice:${ice.peer}`, ice) }
        await this.scheduleExpiry()
        await this.broadcastPeers()
        await Promise.all([...members.map(async member => { try { await this.close(member) } catch { /* Retain for retry. */ } }),
            ...orphans.map(async ice => { try { await this.turn.remove(ice) } catch { /* Retain for retry. */ } })])
        await this.scheduleExpiry()
        if ((await this.members()).some(m => m.owner.startsWith(prefix)) || (await this.turn.all()).some(ice => ice.owner.startsWith(prefix))) return json({ pending: true }, 503)
        // Release by both private account and public generation. A delayed old
        // cleanup must not release a newly registered account's reservation.
        const released = await this.usage('release-account-room', { ...body, roomID: this.state.id.toString() })
        if (!released.ok) return released
        await this.detachIfEmpty(body.publicUserID, body.accountID)
        await this.scheduleExpiry()
        return json({})
    }
    private async handle(request: Request): Promise<Response> {
        const url = new URL(request.url), owner = request.headers.get('X-Owner')!
        const userID = request.headers.get('X-User') ?? undefined
        const members = await this.members()
        const iceMatch = url.pathname.match(/\/ice\/([a-zA-Z0-9_-]{1,80})$/)
        if (iceMatch) {
            const peer = iceMatch[1], b = await readJSON(request)
            if (typeof b.leaseID !== 'string' || !/^[a-zA-Z0-9_-]{1,80}$/.test(b.leaseID)) return json({ error: 'Invalid ICE lease' }, 400)
            const current = await this.turn.get(peer)
            if (current && current.owner !== owner) return json({ error: 'Forbidden' }, 403)
            if (current && current.leaseID !== b.leaseID) return json({ error: 'ICE lease changed' }, 409)
            if (request.method === 'DELETE') {
                if (members.some(m => m.id === peer)) return json({ error: 'Session owns ICE lease' }, 409)
                if (current) {
                    try { await this.turn.remove(current); await this.usage('release', { id: `${this.state.id}:${peer}` }) }
                    finally { await this.scheduleExpiry() }
                }
                await this.scheduleExpiry(); return json({})
            }
            if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
            if (!this.turn.enabled) return json({ iceServers: stun })
            if (!this.turn.configured) return json({ error: 'TURN is not configured' }, 503)
            if (members.some(m => m.id === peer)) return json({ error: 'Participant already connected' }, 409)
            const pending = await this.turn.all()
            if (!current && new Set([...members.map(m => m.id), ...pending.map(m => m.peer)]).size >= limit(this.env.MAX_ROOM_PARTICIPANTS, 8, 8)) return json({ error: 'Room is full' }, 429)
            const reservation = await this.usage('reserve', { id: `${this.state.id}:${peer}`, owner, userID })
            if (!reservation.ok) return reservation
            const { expiresAt } = await reservation.json() as { expiresAt: number }
            try { return json({ iceServers: await this.turn.issue(peer, owner, b.leaseID, expiresAt) }) }
            finally { await this.scheduleExpiry() }
        }
        if (url.pathname.endsWith('/join') && request.method === 'POST') {
            const b = await readJSON(request)
            if (typeof b.participantId !== 'string' || !/^[a-zA-Z0-9_-]{1,63}$/.test(b.participantId)
                || !dataDescription(b.offer, 'offer') || b.offer.sdp.split(/\r?\n/).filter((l: string) => l.startsWith('m=')).length !== 1) return json({ error: 'One SCTP application section is required' }, 400)
            if (members.some(m => m.id === b.participantId)) return json({ error: 'Participant already connected' }, 409)
            if (members.length >= limit(this.env.MAX_ROOM_PARTICIPANTS, 8, 8)) return json({ error: 'Room is full' }, 429)
            if (this.turn.enabled) {
                const ice = await this.turn.get(b.participantId)
                if (!ice || ice.owner !== owner || ice.leaseID !== b.iceLeaseID || ice.expiresAt <= Date.now() || !ice.servers.length) return json({ error: 'Valid ICE lease required' }, 403)
            }
            const leaseID = `${this.state.id}:${b.participantId}`
            const reservation = await this.usage('reserve', { id: leaseID, owner, userID })
            if (!reservation.ok) return reservation
            const { expiresAt } = await reservation.json() as { expiresAt: number }
            let member: Member | undefined
            try {
                const created = await sfu(this.env, '/sessions/new')
                if (typeof created.sessionId !== 'string') throw new Error('upstream')
                member = { id: b.participantId, owner, sessionId: created.sessionId, expiresAt, channels: [], subscriptions: [] }
                // Persist before publishing; a lost upstream response must still be cleaned up.
                await this.state.storage.put(`member:${member.sessionId}`, member)
                await this.scheduleExpiry()
                const result = await sfu(this.env, `/sessions/${member.sessionId}/datachannels/establish`, {
                    sessionDescription: b.offer, dataChannel: { location: 'remote', dataChannelName: 'server-events' }
                })
                if (result.sessionDescription?.type !== 'answer' || !Number.isInteger(result.dataChannel?.id)) throw new Error('upstream')
                member.channels = [result.dataChannel.id]
                await this.state.storage.put(`member:${member.sessionId}`, member)
                return json({ ...this.lease(member), sessionDescription: result.sessionDescription,
                    channels: [{ id: result.dataChannel.id, isPublisher: false, delivery: 'reliable' }] })
            } catch (e) {
                if (member) { member.expiresAt = 0; await this.state.storage.put(`member:${member.sessionId}`, member); await this.state.storage.setAlarm(Date.now() + 1000) }
                // A created session keeps its slot until cleanup confirms its media is gone.
                if (!member) await this.usage('release', { id: leaseID })
                throw e
            }
        }
        const match = url.pathname.match(/\/sessions\/([^/]+)(?:\/(\w+))?$/)
        const member = members.find(m => m.sessionId === match?.[1])
        if (!member) return json({ error: 'Session not found' }, 404)
        if (member.owner !== owner) return json({ error: 'Forbidden' }, 403)
        if (member.expiresAt <= Date.now()) return json({ error: 'Lease expired' }, 410)
        const action = match?.[2]
        if (!action && request.method === 'DELETE') {
            member.expiresAt = 0
            await this.state.storage.put(`member:${member.sessionId}`, member)
            await this.state.storage.setAlarm(Date.now() + 1000)
            await this.close(member); await this.broadcastPeers(); await this.scheduleExpiry(); return json({})
        }
        if (action === 'signal' && request.headers.get('Upgrade')?.toLowerCase() === 'websocket') {
            if (this.state.getWebSockets(member.sessionId).length) return json({ error: 'Signaling already connected' }, 409)
            const pair = new WebSocketPair(); this.state.acceptWebSocket(pair[1], [member.sessionId])
            pair[1].serializeAttachment({ count: 0, minute: 0 }); await this.broadcastPeers()
            return new Response(null, { status: 101, webSocket: pair[0] })
        }
        if (action === 'renew' && request.method === 'POST') {
            const r = await this.usage('reserve', { id: `${this.state.id}:${member.id}`, owner, userID })
            if (!r.ok) return r
            member.expiresAt = (await r.json() as { expiresAt: number }).expiresAt
            await this.state.storage.put(`member:${member.sessionId}`, member); await this.scheduleExpiry()
            const ice = await this.turn.get(member.id)
            const iceServers = ice ? await this.turn.issue(member.id, owner, ice.leaseID, member.expiresAt) : undefined
            return json({ ...this.lease(member), ...(iceServers ? { iceServers } : {}) })
        }
        if (action === 'publish' && request.method === 'POST') {
            if (!member.publishers) {
                const result = await this.allocate(member, {
                    dataChannels: [{ location: 'local', dataChannelName: 'group-audio-v1', ordered: false, maxRetransmits: 0 }, { location: 'local', dataChannelName: 'group-control-v1', ordered: true }]
                })
                member.publishers = ['group-audio-v1', 'group-control-v1'].map(name => {
                    const channel = result.dataChannels?.find((c: any) => c.dataChannelName === name)
                    if (!Number.isInteger(channel?.id)) throw new Error('upstream')
                    return { id: channel.id, delivery: name === 'group-audio-v1' ? 'unreliable' : 'reliable' }
                })
                await this.state.storage.put(`member:${member.sessionId}`, member)
                await this.broadcastPeers()
            }
            return json({ channels: member.publishers.map(c => ({ ...c, isPublisher: true })) })
        }
        if (action === 'pull' && request.method === 'POST') {
            const b = await readJSON(request)
            if (!Array.isArray(b.peerIds) || b.peerIds.length > 7 || b.peerIds.some((id: unknown) => typeof id !== 'string')) return json({ error: 'Invalid peers' }, 400)
            const peers = members.filter(m => m.id !== member.id && b.peerIds.includes(m.id) && m.publishers !== undefined && m.expiresAt > Date.now())
            if (new Set(b.peerIds).size !== peers.length) return json({ error: 'Peer not in room' }, 403)
            const live = new Set(members.filter(m => m.expiresAt > Date.now()).map(m => m.sessionId))
            const stale = member.subscriptions.filter(s => !live.has(s.sessionId))
            if (stale.length) {
                await this.closeChannels(member.sessionId, stale.map(s => s.id))
                member.channels = member.channels.filter(id => !stale.some(s => s.id === id))
                member.subscriptions = member.subscriptions.filter(s => live.has(s.sessionId))
                await this.state.storage.put(`member:${member.sessionId}`, member)
            }
            const fresh = peers.filter(p => !member.subscriptions.some(s => s.sessionId === p.sessionId))
            if (fresh.length) {
                const result = await this.allocate(member, {
                    dataChannels: fresh.flatMap(p => [{ location: 'remote', sessionId: p.sessionId, dataChannelName: 'group-audio-v1', ordered: false, maxRetransmits: 0 }, { location: 'remote', sessionId: p.sessionId, dataChannelName: 'group-control-v1', ordered: true }])
                })
                for (const peer of fresh) {
                    for (const name of ['group-audio-v1', 'group-control-v1']) {
                        const channel = result.dataChannels?.find((c: any) => c.sessionId === peer.sessionId && c.dataChannelName === name)
                        if (!Number.isInteger(channel?.id)) throw new Error('upstream')
                        member.subscriptions.push({ sessionId: peer.sessionId, id: channel.id, peerId: peer.id, delivery: name === 'group-audio-v1' ? 'unreliable' : 'reliable' })
                    }
                }
                await this.state.storage.put(`member:${member.sessionId}`, member)
            }
            return json({ channels: member.subscriptions.map(s => ({ id: s.id, peerID: s.peerId, isPublisher: false, delivery: s.delivery })) })
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
        if (!d || Array.isArray(d) || typeof d !== 'object' || d.type !== 'appData' || typeof d.namespace !== 'string' || d.namespace.length > 128 || typeof d.payload !== 'string') { ws.close(1008, 'Invalid message'); return }
        const result = JSON.stringify({ type: 'appData', from: member.id, namespace: d.namespace, payload: d.payload })
        for (const socket of this.state.getWebSockets()) if (socket !== ws) { try { socket.send(result) } catch { /* closed */ } }
    }
    webSocketClose(ws: WebSocket): void { try { ws.close(1000, 'Closed') } catch { /* closed */ } }
    webSocketError(ws: WebSocket): void { this.webSocketClose(ws) }
    private async broadcastPeers() {
        const peers = (await this.members()).filter(m => m.publishers !== undefined && m.expiresAt > Date.now()).map(m => ({ id: m.id, sessionId: m.sessionId }))
        for (const ws of this.state.getWebSockets()) { try { ws.send(JSON.stringify({ type: 'peers', peers })) } catch { /* closed */ } }
    }
    private async close(member: Member) {
        try {
            const status = await sfu(this.env, `/sessions/${member.sessionId}`, undefined, 'GET')
            const known = (status.dataChannels ?? []).filter((c: any) => c.status !== 'inactive' && Number.isInteger(c.id)).map((c: any) => c.id)
            await this.closeChannels(member.sessionId, [...new Set([...member.channels, ...known])])
            // A timed-out allocation can complete after a status read. Keep its
            // cleanup record until the provider confirms the session is gone.
            if (member.allocationPending) throw new Error('pending-allocation')
        } catch (e) { if (!(e instanceof Error && e.message === 'session-gone')) throw e }
        const ice = await this.turn.get(member.id)
        if (ice) await this.turn.remove(ice)
        await this.state.storage.delete(`member:${member.sessionId}`)
        await this.usage('release', { id: `${this.state.id}:${member.id}` })
        for (const ws of this.state.getWebSockets(member.sessionId)) { try { ws.close(1000, 'Session ended') } catch { /* closed */ } }
    }
    private async allocate(member: Member, body: { dataChannels: any[] }) {
        member.allocationPending = true
        await this.state.storage.put(`member:${member.sessionId}`, member)
        try {
            const result = await sfu(this.env, `/sessions/${member.sessionId}/datachannels/new`, body)
            for (const channel of result.dataChannels ?? []) if (Number.isInteger(channel.id) && !channel.errorCode) member.channels.push(channel.id)
            member.channels = [...new Set(member.channels)]
            member.allocationPending = false
            await this.state.storage.put(`member:${member.sessionId}`, member)
            if (result.dataChannels?.length !== body.dataChannels.length || result.dataChannels.some((c: any) => c.errorCode || !Number.isInteger(c.id))) throw new Error('upstream')
            return result
        } catch (error) {
            member.expiresAt = 0
            await this.state.storage.put(`member:${member.sessionId}`, member)
            await this.state.storage.setAlarm(Date.now() + 1000)
            throw error
        }
    }
    private async closeChannels(sessionID: string, ids: number[]) {
        if (!ids.length) return
        const result = await sfu(this.env, `/sessions/${sessionID}/datachannels/close`, { dataChannels: ids.map(id => ({ id })) }, 'PUT')
        // A partial/missing response is not evidence of cleanup. Retain the lease for retry.
        for (const id of ids) if (!result.dataChannels?.some((c: any) => c.id === id && (!c.errorCode || c.errorCode === 'close_track_error'))) throw new Error('upstream')
    }
    private async scheduleExpiry() {
        const members = await this.members()
        const ice = await this.turn.all()
        const deadlines = [...members.map(m => m.expiresAt), ...ice.map(m => m.expiresAt)]
        if (deadlines.length) await this.state.storage.setAlarm(Math.max(Date.now() + 1000, Math.min(...deadlines)))
        else if ((await this.state.storage.list({ prefix: 'account:' })).size) await this.state.storage.setAlarm(Date.now() + 30000)
        else await this.state.storage.deleteAlarm()
    }
    async alarm(): Promise<void> {
        await this.state.blockConcurrencyWhile(async () => {
        const members = await this.members()
        const expired = members.filter(m => m.expiresAt <= Date.now() || this.env.SERVICE_ENABLED !== 'true')
        const active = new Set(members.map(m => m.id))
        const orphans = (await this.turn.all()).filter(ice => !active.has(ice.peer)
            && (ice.expiresAt <= Date.now() || this.env.SERVICE_ENABLED !== 'true'))
        // Member cleanup can take status + channel close + TURN revoke (3 x 8s).
        // Start orphan revocations concurrently so they do not add another 8s.
        // The snapshot excludes member-owned keys; no credential is revoked twice.
        await Promise.all([...expired.map(async m => {
            try { await this.close(m) } catch { /* Keep cleanup record and retry. */ }
        }), ...orphans.map(async ice => {
            try { await this.turn.remove(ice); await this.usage('release', { id: `${this.state.id}:${ice.peer}` }) } catch { /* Retain for retry/TTL expiry. */ }
        })])
        await this.broadcastPeers()
        for (const [key, accountID] of await this.state.storage.list<string>({ prefix: 'account:' })) {
            try { await this.detachIfEmpty(key.slice('account:'.length), accountID) } catch { /* Retry with the room alarm. */ }
        }
        const remaining = await this.members()
        if (remaining.some(m => m.expiresAt <= Date.now()) || (await this.turn.all()).some(m => m.expiresAt <= Date.now())) await this.state.storage.setAlarm(Date.now() + 30000)
        else await this.scheduleExpiry()
        })
    }
}
