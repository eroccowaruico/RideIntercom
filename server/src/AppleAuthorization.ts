import { createRemoteJWKSet, jwtVerify } from 'jose'
import type { Env } from './types'

// Neither tokens nor request bodies can select the verification or token origin.
export const appleKeys = createRemoteJWKSet(new URL('https://appleid.apple.com/auth/keys'), { timeoutDuration: 5000 })

async function request(env: Env, path: 'token' | 'revoke', fields: Record<string, string>): Promise<Response> {
    if (!env.APPLE_CLIENT_ID || !env.APPLE_CLIENT_SECRET) throw new Error('Apple authorization unavailable')
    return fetch(`https://appleid.apple.com/auth/${path}`, {
        method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(8000),
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ client_id: env.APPLE_CLIENT_ID, client_secret: env.APPLE_CLIENT_SECRET, ...fields })
    })
}

export async function appleDeletionToken(env: Env, code: string, subject: string, nonce: string): Promise<string> {
    const response = await request(env, 'token', { code, grant_type: 'authorization_code' })
    if (!response.ok) { await response.body?.cancel(); throw new Error('Apple authorization unavailable') }
    const reader = response.body?.getReader()
    if (!reader) throw new Error('Apple authorization unavailable')
    const chunks: Uint8Array[] = []; let length = 0
    try {
        for (;;) {
            const { done, value } = await reader.read(); if (done) break
            length += value.byteLength
            if (length > 32768) { await reader.cancel(); throw new Error('Apple authorization unavailable') }
            chunks.push(value)
        }
    } finally { reader.releaseLock() }
    const bytes = new Uint8Array(length); let offset = 0
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length }
    const body = JSON.parse(new TextDecoder().decode(bytes))
    if (typeof body.refresh_token !== 'string' || !body.refresh_token || body.refresh_token.length > 8192
        || typeof body.id_token !== 'string' || body.id_token.length > 16384) throw new Error('Apple authorization unavailable')
    const { payload } = await jwtVerify(body.id_token, appleKeys, {
        algorithms: ['RS256'], issuer: 'https://appleid.apple.com', audience: env.APPLE_CLIENT_ID,
        requiredClaims: ['sub', 'iat', 'exp', 'nonce'], clockTolerance: 0
    })
    // A code for another user must never be used to revoke their authorization.
    if (payload.sub !== subject || payload.aud !== env.APPLE_CLIENT_ID || payload.nonce !== nonce
        || typeof payload.iat !== 'number' || payload.iat > Date.now() / 1000 + 60) throw new Error('Apple authorization unavailable')
    return body.refresh_token
}

export async function revokeAppleAuthorization(env: Env, token: string): Promise<void> {
    const response = await request(env, 'revoke', { token, token_type_hint: 'refresh_token' })
    await response.body?.cancel()
    // Apple also returns 200 for a token it has already invalidated.
    if (response.status !== 200) throw new Error('Apple authorization unavailable')
}
