import { importPKCS8, SignJWT } from 'jose'
import type { Env } from './types'
import type { NotificationDevice } from './AccountNotifications'

export function notificationsConfigured(env: Env): boolean {
    return env.NOTIFICATIONS_ENABLED === 'true' && !!env.DEVICE_IDENTITY_SIGNING_KEY && !!env.APNS_PRIVATE_KEY
        && !!env.APNS_KEY_ID && !!env.APNS_TEAM_ID && !!env.APNS_TOPIC
        && ['sandbox', 'production'].includes(env.APNS_ENVIRONMENT ?? '')
}

// Reusable provider credential only: no user/request state. A single isolate-local entry
// avoids per-push signing; production connection reuse remains an APNs acceptance check.
let providerCredential: { configuration: string; issuedAt: number; token: Promise<string> } | undefined
export async function notificationProviderToken(env: Env): Promise<string> {
    const configuration = JSON.stringify([env.APNS_PRIVATE_KEY, env.APNS_KEY_ID, env.APNS_TEAM_ID])
    const issuedAt = Math.floor(Date.now() / 1000)
    if (providerCredential?.configuration === configuration && issuedAt >= providerCredential.issuedAt
        && issuedAt - providerCredential.issuedAt < 50 * 60) return providerCredential.token
    const entry = { configuration, issuedAt, token: (async () => {
        const key = await importPKCS8(env.APNS_PRIVATE_KEY!, 'ES256')
        return new SignJWT({}).setProtectedHeader({ alg: 'ES256', kid: env.APNS_KEY_ID! })
            .setIssuer(env.APNS_TEAM_ID!).setIssuedAt(issuedAt).sign(key)
    })() }
    providerCredential = entry
    try { return await entry.token }
    catch (error) { if (providerCredential === entry) providerCredential = undefined; throw error }
}

export type NotificationDeliveryResult = 'accepted' | 'invalid_token' | 'retry_later' | 'rejected'
/** Native fetch is the production candidate; tests intercept it before any external I/O. */
export async function deliverNotification(device: NotificationDevice, providerToken: string,
                                        requestID: string, recipientID: string, expiresAt: number): Promise<NotificationDeliveryResult> {
    const host = device.environment === 'sandbox' ? 'api.sandbox.push.apple.com' : 'api.push.apple.com'
    try {
        const response = await fetch(`https://${host}/3/device/${device.token}`, {
            method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(8000),
            headers: { authorization: `bearer ${providerToken}`, 'content-type': 'application/json',
                'apns-topic': device.topic, 'apns-push-type': 'alert', 'apns-priority': '10',
                'apns-id': requestID, 'apns-collapse-id': requestID, 'apns-expiration': String(Math.floor(expiresAt / 1000)) },
            body: JSON.stringify({ aps: { alert: { 'title-loc-key': 'CALL_REQUEST_TITLE', 'loc-key': 'CALL_REQUEST_BODY' }, sound: 'default' },
                version: 1, requestID, recipientID })
        })
        // No provider body, token or payload is logged or forwarded to callers.
        await response.body?.cancel()
        if (response.status === 200) return 'accepted'
        if (response.status === 410) return 'invalid_token'
        if (response.status === 429 || response.status >= 500) return 'retry_later'
        return 'rejected'
    } catch { return 'retry_later' }
}
