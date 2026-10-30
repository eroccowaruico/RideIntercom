import { DurableObject } from 'cloudflare:workers'
import { createRemoteJWKSet, errors, jwtVerify } from 'jose'
import { Env, json, readJSON } from './types'

// Only Apple's fixed public-key origin is used; a token cannot choose a key URL.
const appleKeys = createRemoteJWKSet(new URL('https://appleid.apple.com/auth/keys'), { timeoutDuration: 5000 })
const devicePattern = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i
const objectPattern = /^[a-f0-9]{64}$/
const randomSecret = () => hex(crypto.getRandomValues(new Uint8Array(32)))
const hex = (bytes: Uint8Array) => Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('')
const digest = async (secret: string) => hex(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(secret))))
interface Challenge { deviceID: string; nonce: string; issuedAt: number; expiresAt: number }
interface DeletionReceipt { deviceID: string; tokenHash: string; deletedAt: number; expiresAt: number }
interface Device { tokenHash: string; expiresAt: number }
export interface DeviceIdentity { userID: string; deviceID: string; expiresAt: number }

export class AppleAuthAttempt extends DurableObject<Env> {
    async issue(deviceID: string): Promise<Challenge & { challengeID: string }> {
        const attempt = { deviceID, nonce: randomSecret(), issuedAt: Date.now(), expiresAt: Date.now() + 300000 }
        this.ctx.storage.kv.put('challenge', attempt)
        await this.ctx.storage.setAlarm(attempt.expiresAt)
        return { ...attempt, challengeID: this.ctx.id.toString() }
    }

    async exchange(identityToken: string): Promise<{ subject: string; deviceID: string; issuedAt: number } | null> {
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
        return { subject, deviceID: attempt.deviceID, issuedAt: attempt.issuedAt }
    }

    async alarm(): Promise<void> { await this.ctx.storage.deleteAll() }
}

export class UserAccount extends DurableObject<Env> {
    async register(deviceID: string, tokenHash: string, issuedAt: number): Promise<DeviceIdentity | 'stale-proof' | null> {
        this.prune()
        const deletion = this.ctx.storage.kv.get<DeletionReceipt>('deletion')
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

    async erase(deviceID: string, tokenHash: string): Promise<boolean> {
        this.prune()
        const receipt = this.ctx.storage.kv.get<DeletionReceipt>('deletion')
        if (receipt?.deviceID === deviceID && receipt.tokenHash === tokenHash) {
            // A lost DELETE response can be retried, even after a new sign-in.
            // Never apply an old successful deletion to the new registrations.
            await this.scheduleExpiry()
            return true
        }
        if (!this.authenticate(deviceID, tokenHash)) return false
        const now = Date.now()
        this.ctx.storage.transactionSync(() => {
            this.ctx.storage.kv.delete('userID')
            for (const [key] of this.ctx.storage.kv.list({ prefix: 'device:' })) this.ctx.storage.kv.delete(key)
            // One bounded receipt, containing a hash rather than the bearer secret.
            // Its timestamp also excludes previously issued enrollment proofs.
            this.ctx.storage.kv.put('deletion', { deviceID, tokenHash, deletedAt: now, expiresAt: now + 86400000 })
        })
        await this.scheduleExpiry()
        return true
    }

    private prune() {
        const receipt = this.ctx.storage.kv.get<DeletionReceipt>('deletion')
        if (receipt && receipt.expiresAt <= Date.now()) this.ctx.storage.kv.delete('deletion')
        for (const [key, device] of this.ctx.storage.kv.list<Device>({ prefix: 'device:' })) {
            if (device.expiresAt <= Date.now()) this.ctx.storage.kv.delete(key)
        }
    }
    private async scheduleExpiry() {
        const devices = [...this.ctx.storage.kv.list<Device>({ prefix: 'device:' })].map(([, device]) => device)
        const receipt = this.ctx.storage.kv.get<DeletionReceipt>('deletion')
        const deadlines = [...devices.map(device => device.expiresAt), ...(receipt ? [receipt.expiresAt] : [])]
        if (deadlines.length) await this.ctx.storage.setAlarm(Math.min(...deadlines))
        else await this.ctx.storage.deleteAlarm()
    }
    async alarm(): Promise<void> { this.prune(); await this.scheduleExpiry() }
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
        if (path === '/api/auth/session' || path === '/api/auth/account') {
            const authorization = request.headers.get('Authorization') ?? ''
            const credential = authorization.startsWith('Bearer ') && authorization.length <= 512
                ? deviceCredential(authorization.slice(7), env) : null
            if (!credential) return json({ error: 'Unauthorized' }, 401)
            const tokenHash = await digest(credential.secret)
            if (path === '/api/auth/account') {
                if (request.method !== 'DELETE') return json({ error: 'Method not allowed' }, 405)
                return await credential.account.erase(credential.deviceID, tokenHash)
                    ? json({ deleted: true, appleAuthorizationRevoked: false }) : json({ error: 'Unauthorized' }, 401)
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
        if (identity === 'stale-proof') return json({ error: 'Prepare Apple sign-in again' }, 401)
        if (!identity) return json({ error: 'Device registration limit reached', code: 'device_limit_reached' }, 409)
        return json({ ...identity, accessToken: `ri1.${account.id.toString()}.${identity.deviceID}.${secret}` })
    } catch (error) {
        return error instanceof Error && error.message === 'body'
            ? json({ error: 'Invalid body' }, 400) : json({ error: 'Account service unavailable' }, 503)
    }
}
