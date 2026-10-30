import { base64url, importJWK, SignJWT } from 'jose'
import { Env } from './types'
import type { DeviceIdentity } from './AppleAccount'

export async function certifyDevice(identity: DeviceIdentity, issuer: string, body: Record<string, unknown>, env: Env) {
    const memberID = body.memberID, deviceKey = body.deviceKey
    if (typeof memberID !== 'string' || !/^[A-Za-z0-9_-]{1,63}$/.test(memberID) || memberID.startsWith('invite-pending-')
        || typeof deviceKey !== 'string' || deviceKey.length !== 87) throw new Error('body')
    try {
        const bytes = base64url.decode(deviceKey)
        if (bytes.length !== 65 || bytes[0] !== 4 || base64url.encode(bytes) !== deviceKey) throw new Error('key')
        await crypto.subtle.importKey('raw', bytes, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify'])
    } catch { throw new Error('body') }
    if (!env.DEVICE_IDENTITY_SIGNING_KEY) throw new Error('configuration')
    const stored = JSON.parse(env.DEVICE_IDENTITY_SIGNING_KEY)
    if (stored.kty !== 'EC' || stored.crv !== 'P-256' || typeof stored.d !== 'string'
        || typeof stored.x !== 'string' || typeof stored.y !== 'string') throw new Error('configuration')
    const x = base64url.decode(stored.x), y = base64url.decode(stored.y)
    if (x.length !== 32 || y.length !== 32) throw new Error('configuration')
    const key = await importJWK({ kty: 'EC', crv: 'P-256', x: stored.x, y: stored.y, d: stored.d }, 'ES256')
    const issuerKey = base64url.encode(new Uint8Array([4, ...x, ...y]))
    const issuedAt = Math.floor(Date.now() / 1000)
    const expiresAt = Math.min(Math.floor(identity.expiresAt / 1000), issuedAt + 30 * 86400)
    if (expiresAt <= issuedAt) throw new Error('expired')
    const certificate = await new SignJWT({ deviceID: identity.deviceID, memberID, deviceKey })
        .setProtectedHeader({ alg: 'ES256', typ: 'rideintercom-device+jwt' })
        .setIssuer(issuer).setSubject(identity.userID).setAudience('rideintercom-peer')
        .setIssuedAt(issuedAt).setExpirationTime(expiresAt).sign(key)
    return { certificate, issuerKey }
}
