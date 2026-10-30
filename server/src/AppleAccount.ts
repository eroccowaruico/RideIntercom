import { DurableObject } from 'cloudflare:workers'
import { errors, jwtVerify } from 'jose'
import { Env, json, readJSON } from './types'
import { certifyDevice } from './DeviceIdentity'

import { appleKeys, appleDeletionToken, revokeAppleAuthorization } from './AppleAuthorization'
const devicePattern = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i
const objectPattern = /^[a-f0-9]{64}$/
const randomSecret = () => hex(crypto.getRandomValues(new Uint8Array(32)))
const hex = (bytes: Uint8Array) => Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('')
const digest = async (secret: string) => hex(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(secret))))
interface Challenge { deviceID: string; nonce: string; issuedAt: number; expiresAt: number }
interface DeletionReceipt {
    userID?: string; observers?: { deviceID: string; tokenHash: string }[]
    deviceID: string; tokenHash: string; deletedAt: number; expiresAt: number
    rooms?: string[]; mediaAttempts?: number; mediaRetryAt?: number
    appleToken?: string; appleAuthorizationRevoked?: boolean; attempts?: number; retryAt?: number
}
interface DeletionPreparation { id: string; expiresAt: number }
interface DeletionResult { deleted: true; appleAuthorizationRevoked: boolean; appleRevocationPending?: true; newerAccountPreserved?: true; mediaCleanupPending?: true }
const retryDelays = [60000, 300000, 1800000, 7200000, 21600000]
interface Device { tokenHash: string; expiresAt: number }
export interface DeviceIdentity { userID: string; deviceID: string; expiresAt: number }

export class AppleAuthAttempt extends DurableObject<Env> {
    async issue(deviceID: string): Promise<Challenge & { challengeID: string }> {
        const attempt = { deviceID, nonce: randomSecret(), issuedAt: Date.now(), expiresAt: Date.now() + 300000 }
        this.ctx.storage.kv.put('challenge', attempt)
        await this.ctx.storage.setAlarm(attempt.expiresAt)
        return { ...attempt, challengeID: this.ctx.id.toString() }
    }

    async exchange(identityToken: string): Promise<{ subject: string; deviceID: string; issuedAt: number; nonce: string } | null> {
        const attempt = this.ctx.storage.kv.get<Challenge>('challenge')
        if (!attempt || attempt.expiresAt <= Date.now()) return null
        // Reserve a verification attempt before any external await. Restarting
        // the object or racing requests must not reset the work budget.
        const count = this.ctx.storage.kv.get<number>('verificationAttempts') ?? 0
        if (count >= 5) return null
        this.ctx.storage.kv.put('verificationAttempts', count + 1)
        let subject: string
        try {
            const { payload } = await jwtVerify(identityToken, appleKeys, {
                algorithms: ['RS256'], issuer: 'https://appleid.apple.com', audience: this.env.APPLE_CLIENT_ID,
                requiredClaims: ['sub', 'iat', 'exp', 'nonce'], clockTolerance: 0
            })
            if (payload.nonce !== attempt.nonce || payload.aud !== this.env.APPLE_CLIENT_ID
                || typeof payload.sub !== 'string' || !payload.sub || payload.sub.length > 1024
                || typeof payload.iat !== 'number' || payload.iat > Date.now() / 1000 + 60) return null
            subject = payload.sub
        } catch (error) {
            if (error instanceof errors.JOSEError && !['ERR_JWKS_TIMEOUT', 'ERR_JWKS_INVALID'].includes(error.code)) return null
            throw new Error('Apple verification unavailable')
        }
        // Verification can suspend. Consume synchronously after rechecking so two
        // concurrent exchanges cannot mint credentials from the same proof.
        const current = this.ctx.storage.kv.get<Challenge>('challenge')
        if (!current || current.nonce !== attempt.nonce || current.expiresAt <= Date.now()) return null
        this.ctx.storage.kv.delete('challenge')
        this.ctx.storage.kv.delete('verificationAttempts')
        await this.ctx.storage.deleteAlarm()
        return { subject, deviceID: attempt.deviceID, issuedAt: attempt.issuedAt, nonce: attempt.nonce }
    }

    async alarm(): Promise<void> { await this.ctx.storage.deleteAll() }
}

export class UserAccount extends DurableObject<Env> {
    async register(deviceID: string, tokenHash: string, issuedAt: number): Promise<DeviceIdentity | 'stale-proof' | 'deletion-pending' | null> {
        this.prune()
        const deletion = this.ctx.storage.kv.get<DeletionReceipt>('deletion')
        if (deletion?.appleToken || deletion?.rooms?.length || this.ctx.storage.kv.get('deletionPreparation')) return 'deletion-pending'
        if (deletion && (!Number.isFinite(issuedAt) || issuedAt <= deletion.deletedAt)) return 'stale-proof'
        if (!this.ctx.storage.kv.get(`device:${deviceID}`) && [...this.ctx.storage.kv.list({ prefix: 'device:' })].length >= 8) return null
        const expiresAt = Date.now() + 30 * 86400000
        // Public identity is stable across device expiry/sign-out, and retired only
        // by account deletion. Never derive it from the private DO locator.
        const userID = this.ctx.storage.kv.get<string>('userID') ?? randomSecret()
        if (!objectPattern.test(userID)) throw new Error('Invalid account identity')
        this.ctx.storage.transactionSync(() => {
            this.ctx.storage.kv.put('userID', userID)
            this.ctx.storage.kv.put(`device:${deviceID}`, { tokenHash, expiresAt })
        })
        await this.scheduleExpiry()
        return { userID, deviceID, expiresAt }
    }

    attachRoom(publicUserID: string, roomID: string): boolean {
        if (!objectPattern.test(roomID) || this.ctx.storage.kv.get('userID') !== publicUserID) return false
        const key = `room:${roomID}`
        if (!this.ctx.storage.kv.get(key) && [...this.ctx.storage.kv.list({ prefix: 'room:' })].length >= 8) return false
        // Index before any provider allocation. Deletion atomically transfers this
        // reference into its outbox, including operations still queued in the room.
        this.ctx.storage.kv.put(key, publicUserID)
        return true
    }
    detachRoom(publicUserID: string, roomID: string): void {
        if (this.ctx.storage.kv.get(`room:${roomID}`) === publicUserID) this.ctx.storage.kv.delete(`room:${roomID}`)
    }

    authenticate(deviceID: string, tokenHash: string): DeviceIdentity | null {
        const userID = this.ctx.storage.kv.get<string>('userID')
        const device = this.ctx.storage.kv.get<Device>(`device:${deviceID}`)
        if (!userID || !objectPattern.test(userID) || !device || device.expiresAt <= Date.now() || !crypto.subtle.timingSafeEqual(
            new TextEncoder().encode(device.tokenHash), new TextEncoder().encode(tokenHash))) return null
        return { userID, deviceID, expiresAt: device.expiresAt }
    }

    async revoke(deviceID: string, tokenHash: string): Promise<boolean> {
        if (!this.authenticate(deviceID, tokenHash)) return false
        this.ctx.storage.kv.delete(`device:${deviceID}`)
        await this.scheduleExpiry()
        return true
    }

    deletionResult(deviceID: string, tokenHash: string): DeletionResult | null {
        this.prune()
        const receipt = this.ctx.storage.kv.get<DeletionReceipt>('deletion')
        if (!receipt || ![receipt, ...(receipt.observers ?? [])].some(observer => observer.deviceID === deviceID && crypto.subtle.timingSafeEqual(
            new TextEncoder().encode(observer.tokenHash), new TextEncoder().encode(tokenHash)))) return null
        // Receipt retries must not tell an old device to remove a new Apple grant.
        if (this.ctx.storage.kv.get('userID')) return { deleted: true, appleAuthorizationRevoked: false, newerAccountPreserved: true }
        return { deleted: true, appleAuthorizationRevoked: receipt.appleAuthorizationRevoked === true,
            ...(receipt.appleToken ? { appleRevocationPending: true as const } : {}),
            ...(receipt.rooms?.length ? { mediaCleanupPending: true as const } : {}) }
    }

    async eraseWithAppleProof(deviceID: string, tokenHash: string, code: string, subject: string, nonce: string, expectedUserID?: string): Promise<DeletionResult | null> {
        if (this.deletionResult(deviceID, tokenHash)) return this.erase(deviceID, tokenHash)
        // This method is reached only after fresh Apple subject/device verification
        // by the Worker. The public ID constrains the deletion generation; it is
        // never used to select another account's DO.
        if (expectedUserID !== undefined) {
            if (!objectPattern.test(expectedUserID)) return null
            const current = this.ctx.storage.kv.get<string>('userID')
            if (current && current !== expectedUserID) return { deleted: true, appleAuthorizationRevoked: false, newerAccountPreserved: true }
            const receipt = this.ctx.storage.kv.get<DeletionReceipt>('deletion')
            if (!current && receipt?.userID === expectedUserID) {
                // A second owner device may resume a pending cancellation without
                // minting another Apple token or invalidating the original receipt.
                receipt.observers = [...(receipt.observers ?? []).filter(item => item.deviceID !== deviceID), { deviceID, tokenHash }].slice(-8)
                this.ctx.storage.kv.put('deletion', receipt)
                return this.erase(deviceID, tokenHash)
            }
            if (receipt?.appleToken || receipt?.rooms?.length) throw new Error('Previous deletion cleanup pending')
        } else if (!this.authenticate(deviceID, tokenHash)) return null
        if (this.ctx.storage.kv.get('deletionPreparation')) throw new Error('Deletion preparation pending')
        const preparation = { id: crypto.randomUUID(), expiresAt: Date.now() + 30000 }
        this.ctx.storage.kv.put('deletionPreparation', preparation)
        await this.scheduleExpiry()
        try {
            const token = await appleDeletionToken(this.env, code, subject, nonce)
            if (this.ctx.storage.kv.get<DeletionPreparation>('deletionPreparation')?.id !== preparation.id) throw new Error('Deletion preparation expired')
            this.ctx.storage.kv.delete('deletionPreparation')
            return await this.erase(deviceID, tokenHash, token, expectedUserID)
        } finally {
            if (this.ctx.storage.kv.get<DeletionPreparation>('deletionPreparation')?.id === preparation.id) this.ctx.storage.kv.delete('deletionPreparation')
            await this.scheduleExpiry()
        }
    }

    async erase(deviceID: string, tokenHash: string, appleToken?: string, expectedUserID?: string): Promise<DeletionResult | null> {
        if (this.ctx.storage.kv.get('deletionPreparation')) throw new Error('Deletion preparation pending')
        if (!this.deletionResult(deviceID, tokenHash)) {
            const userID = this.ctx.storage.kv.get<string>('userID')
            if (expectedUserID === undefined ? !this.authenticate(deviceID, tokenHash) : userID && userID !== expectedUserID) return null
            const now = Date.now()
            const rooms = [...this.ctx.storage.kv.list<string>({ prefix: 'room:' })].filter(([, owner]) => owner === userID).map(([key]) => key.slice('room:'.length))
            this.ctx.storage.transactionSync(() => {
                this.ctx.storage.kv.delete('userID')
                for (const prefix of ['device:', 'room:']) for (const [key] of this.ctx.storage.kv.list({ prefix })) this.ctx.storage.kv.delete(key)
                // The token is held only for deletion retries, never routine login.
                this.ctx.storage.kv.put('deletion', { userID: userID ?? expectedUserID, deviceID, tokenHash, deletedAt: now, expiresAt: now + 86400000,
                    ...(appleToken ? { appleToken, attempts: 0, retryAt: now } : {}),
                    ...(rooms.length ? { rooms, mediaAttempts: 0, mediaRetryAt: now } : {}) })
            })
        }
        await Promise.all([this.retryAppleRevocation(), this.retryMediaCleanup()])
        await this.scheduleExpiry()
        return this.deletionResult(deviceID, tokenHash)
    }

    private async retryMediaCleanup() {
        const receipt = this.ctx.storage.kv.get<DeletionReceipt>('deletion')
        if (!receipt?.rooms?.length || !receipt.userID || receipt.mediaRetryAt === undefined || receipt.mediaRetryAt > Date.now()) return
        const attempt = receipt.mediaAttempts ?? 0
        receipt.mediaAttempts = Math.min(attempt + 1, retryDelays.length + 1)
        receipt.mediaRetryAt = Date.now() + (retryDelays[attempt] ?? 60000)
        this.ctx.storage.kv.put('deletion', receipt)
        await this.scheduleExpiry()
        const completed = await Promise.all(receipt.rooms.map(async room => {
            try {
                const response = await this.env.SIGNALING_ROOM.get(this.env.SIGNALING_ROOM.idFromString(room)).fetch(new Request('https://internal/retire-account', {
                    method: 'POST', body: JSON.stringify({ publicUserID: receipt.userID, accountID: this.ctx.id.toString() })
                }))
                return response.ok ? room : null
            } catch { return null }
        }))
        const current = this.ctx.storage.kv.get<DeletionReceipt>('deletion')
        if (current?.tokenHash !== receipt.tokenHash || current.userID !== receipt.userID) return
        current.rooms = current.rooms?.filter(room => !completed.includes(room))
        if (!current.rooms?.length) {
            delete current.rooms; delete current.mediaAttempts; delete current.mediaRetryAt
            current.expiresAt = Date.now() + 86400000
        }
        this.ctx.storage.kv.put('deletion', current)
    }

    private async retryAppleRevocation() {
        const receipt = this.ctx.storage.kv.get<DeletionReceipt>('deletion')
        if (!receipt?.appleToken || receipt.retryAt === undefined || receipt.retryAt > Date.now()) return
        const attempt = receipt.attempts ?? 0
        // Persist a bounded retry schedule before external I/O. Concurrent DELETE
        // and alarm requests cannot duplicate this attempt, even after a restart.
        receipt.attempts = Math.min(attempt + 1, retryDelays.length + 1)
        receipt.retryAt = Date.now() + (retryDelays[attempt] ?? 60000)
        this.ctx.storage.kv.put('deletion', receipt)
        await this.scheduleExpiry()
        try { await revokeAppleAuthorization(this.env, receipt.appleToken) }
        catch { return }
        const current = this.ctx.storage.kv.get<DeletionReceipt>('deletion')
        if (current?.tokenHash !== receipt.tokenHash || current.appleToken !== receipt.appleToken) return
        delete current.appleToken; delete current.retryAt; delete current.attempts
        current.appleAuthorizationRevoked = true
        current.expiresAt = Date.now() + 86400000
        this.ctx.storage.kv.put('deletion', current)
    }

    private prune() {
        const preparation = this.ctx.storage.kv.get<DeletionPreparation>('deletionPreparation')
        if (preparation && preparation.expiresAt <= Date.now()) this.ctx.storage.kv.delete('deletionPreparation')
        const receipt = this.ctx.storage.kv.get<DeletionReceipt>('deletion')
        if (receipt && !receipt.appleToken && !receipt.rooms?.length && receipt.expiresAt <= Date.now()) this.ctx.storage.kv.delete('deletion')
        for (const [key, device] of this.ctx.storage.kv.list<Device>({ prefix: 'device:' })) {
            if (device.expiresAt <= Date.now()) this.ctx.storage.kv.delete(key)
        }
    }
    private async scheduleExpiry() {
        const devices = [...this.ctx.storage.kv.list<Device>({ prefix: 'device:' })].map(([, device]) => device)
        const receipt = this.ctx.storage.kv.get<DeletionReceipt>('deletion')
        const preparation = this.ctx.storage.kv.get<DeletionPreparation>('deletionPreparation')
        const pending = !!receipt?.appleToken || !!receipt?.rooms?.length
        const deadlines = [...devices.map(device => device.expiresAt), ...(preparation ? [preparation.expiresAt] : []),
            ...(receipt?.appleToken && receipt.retryAt !== undefined && (receipt.attempts ?? 0) <= retryDelays.length ? [receipt.retryAt] : []),
            ...(receipt?.rooms?.length && receipt.mediaRetryAt !== undefined && (receipt.mediaAttempts ?? 0) <= retryDelays.length ? [receipt.mediaRetryAt] : []),
            ...(receipt && !pending ? [receipt.expiresAt] : [])]
        if (deadlines.length) await this.ctx.storage.setAlarm(Math.min(...deadlines))
        else await this.ctx.storage.deleteAlarm()
    }
    async alarm(): Promise<void> { this.prune(); await Promise.all([this.retryAppleRevocation(), this.retryMediaCleanup()]); await this.scheduleExpiry() }
}

function deviceCredential(token: string, env: Env) {
    const [version, accountID, deviceID, secret, extra] = token.split('.')
    if (version !== 'ri1' || !objectPattern.test(accountID ?? '') || !devicePattern.test(deviceID ?? '')
        || !objectPattern.test(secret ?? '') || extra !== undefined) return null
    try { return { account: env.USER_ACCOUNT.get(env.USER_ACCOUNT.idFromString(accountID)), accountID, deviceID, secret } }
    catch { return null }
}

export async function authenticateDevice(token: string, env: Env): Promise<(DeviceIdentity & { accountID: string }) | null> {
    const credential = deviceCredential(token, env)
    if (!credential) return null
    const identity = await credential.account.authenticate(credential.deviceID, await digest(credential.secret))
    // Internal connection accounting survives public identity retirement, so a
    // still-live lease cannot be bypassed by deleting and registering again.
    return identity ? { ...identity, accountID: credential.accountID } : null
}

export async function accountRequest(request: Request, env: Env): Promise<Response> {
    const path = new URL(request.url).pathname
    try {
        if (path === '/api/auth/identity') {
            if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
            const authorization = request.headers.get('Authorization') ?? ''
            const token = authorization.startsWith('Bearer ') && authorization.length <= 512 ? authorization.slice(7) : ''
            const identity = await authenticateDevice(token, env)
            if (!identity) return json({ error: 'Unauthorized' }, 401)
            const limited = await limitEnrollment(request, env)
            if (limited) return limited
            const result = await certifyDevice(identity, new URL(request.url).origin, await readJSON(request), env)
            // Signing can suspend. Do not deliver a certificate after its device
            // was revoked, replaced, or its account was deleted in the meantime.
            const current = await authenticateDevice(token, env)
            return current?.userID === identity.userID ? json(result) : json({ error: 'Unauthorized' }, 401)
        }
        if (path === '/api/auth/session' || path === '/api/auth/account') {
            const authorization = request.headers.get('Authorization') ?? ''
            const credential = authorization.startsWith('Bearer ') && authorization.length <= 512
                ? deviceCredential(authorization.slice(7), env) : null
            if (!credential) return json({ error: 'Unauthorized' }, 401)
            const tokenHash = await digest(credential.secret)
            if (path === '/api/auth/account') {
                if (request.method !== 'DELETE') return json({ error: 'Method not allowed' }, 405)
                const previous = await credential.account.deletionResult(credential.deviceID, tokenHash)
                if (!previous && request.body) {
                    if (!env.APPLE_CLIENT_SECRET) return json({ error: 'Apple authorization unavailable' }, 503)
                    const limited = await limitEnrollment(request, env); if (limited) return limited
                    const body = await readJSON(request)
                    if (typeof body.challengeID !== 'string' || !objectPattern.test(body.challengeID)
                        || typeof body.identityToken !== 'string' || !body.identityToken || body.identityToken.length > 16384
                        || typeof body.authorizationCode !== 'string' || !body.authorizationCode || body.authorizationCode.length > 8192
                        || (body.expectedUserID !== undefined && (typeof body.expectedUserID !== 'string' || !objectPattern.test(body.expectedUserID)))) return json({ error: 'Invalid proof' }, 400)
                    if (body.expectedUserID === undefined && !await credential.account.authenticate(credential.deviceID, tokenHash)) return json({ error: 'Unauthorized' }, 401)
                    const attempt = env.APPLE_AUTH_ATTEMPT.get(env.APPLE_AUTH_ATTEMPT.idFromString(body.challengeID))
                    const proof = await attempt.exchange(body.identityToken)
                    if (!proof || proof.deviceID !== credential.deviceID
                        || env.USER_ACCOUNT.idFromName(await digest('apple:' + proof.subject)).toString() !== credential.accountID) return json({ error: 'Unauthorized' }, 401)
                    const result = await credential.account.eraseWithAppleProof(credential.deviceID, tokenHash, body.authorizationCode, proof.subject, proof.nonce, body.expectedUserID as string | undefined)
                    return result ? json(result) : json({ error: 'Unauthorized' }, 401)
                }
                const result = await credential.account.erase(credential.deviceID, tokenHash)
                return result ? json(result) : json({ error: 'Unauthorized' }, 401)
            }
            if (request.method === 'DELETE') {
                return await credential.account.revoke(credential.deviceID, tokenHash) ? json({}) : json({ error: 'Unauthorized' }, 401)
            }
            if (request.method !== 'GET') return json({ error: 'Method not allowed' }, 405)
            const identity = await credential.account.authenticate(credential.deviceID, tokenHash)
            return identity ? json(identity) : json({ error: 'Unauthorized' }, 401)
        }
        if (!['/api/auth/apple/challenge', '/api/auth/apple/session'].includes(path)) return json({ error: 'Not found' }, 404)
        if (env.APPLE_AUTH_ENABLED !== 'true' || !env.APPLE_CLIENT_ID) return json({ error: 'Apple enrollment is unavailable' }, 503)
        if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
        const limited = await limitEnrollment(request, env)
        if (limited) return limited
        const body: Record<string, unknown> = await readJSON(request)
        if (path.endsWith('/challenge')) {
            if (typeof body.deviceID !== 'string' || !devicePattern.test(body.deviceID)) return json({ error: 'Invalid device' }, 400)
            const attempt = env.APPLE_AUTH_ATTEMPT.get(env.APPLE_AUTH_ATTEMPT.newUniqueId())
            return json(await attempt.issue(body.deviceID.toLowerCase()))
        }
        if (typeof body.challengeID !== 'string' || !objectPattern.test(body.challengeID)
            || typeof body.identityToken !== 'string' || body.identityToken.length > 16384 || !body.identityToken) return json({ error: 'Invalid proof' }, 400)
        let attempt: DurableObjectStub<AppleAuthAttempt>
        try { attempt = env.APPLE_AUTH_ATTEMPT.get(env.APPLE_AUTH_ATTEMPT.idFromString(body.challengeID)) }
        catch { return json({ error: 'Invalid proof' }, 400) }
        const verified = await attempt.exchange(body.identityToken)
        if (!verified) return json({ error: 'Unauthorized' }, 401)
        // Object names can also appear in provider metadata. Do not use Apple's
        // raw subject as either a stored field or the Durable Object's name.
        const account = env.USER_ACCOUNT.getByName(await digest('apple:' + verified.subject))
        const secret = randomSecret()
        const identity = await account.register(verified.deviceID, await digest(secret), verified.issuedAt)
        if (identity === 'deletion-pending') return json({ error: 'Account deletion is still pending', code: 'deletion_pending' }, 409)
        if (identity === 'stale-proof') return json({ error: 'Prepare Apple sign-in again' }, 401)
        if (!identity) return json({ error: 'Device registration limit reached', code: 'device_limit_reached' }, 409)
        return json({ ...identity, accessToken: `ri1.${account.id.toString()}.${identity.deviceID}.${secret}` })
    } catch (error) {
        return error instanceof Error && error.message === 'body'
            ? json({ error: 'Invalid body' }, 400) : json({ error: 'Account service unavailable' }, 503)
    }
}

async function limitEnrollment(request: Request, env: Env): Promise<Response | null> {
    // Only the edge-provided source is used, never a device ID or a
    // client-selected forwarding header. No source IP is stored in a DO.
    const source = request.headers.get('CF-Connecting-IP')
    if (!source || source.length > 64 || !env.APPLE_ENROLLMENT_IP_LIMIT || !env.APPLE_ENROLLMENT_GLOBAL_LIMIT) {
        return json({ error: 'Apple enrollment is unavailable' }, 503)
    }
    const sourceKey = await digest(`${Math.floor(Date.now() / 86400000)}:${source}`)
    if (!(await env.APPLE_ENROLLMENT_IP_LIMIT.limit({ key: sourceKey })).success
        || !(await env.APPLE_ENROLLMENT_GLOBAL_LIMIT.limit({ key: 'apple-enrollment' })).success) {
        const response = json({ error: 'Too many sign-in attempts', code: 'enrollment_rate_limited' }, 429)
        response.headers.set('Retry-After', '60')
        return response
    }
    return null
}
