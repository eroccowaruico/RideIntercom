
export interface NotificationAuth { accountID: string; userID: string; deviceID: string; tokenHash: string }
export interface NotificationDevice {
    token: string; environment: 'sandbox' | 'production'; topic: string
    registrationID: string; tokenIndex: string; deviceID: string; tokenHash: string; expiresAt: number
}
export type DeliveryStatus = 'processing' | 'accepted' | 'no_destinations' | 'retry_later' | 'rejected' | 'cancelled'
export interface NotificationCall {
    requestID: string; sender: NotificationAuth; recipientID: string; grantHash: string
    expiresAt: number; forgetAt: number; status: DeliveryStatus
}
export const callLifetime = 120_000
export const dedupeLifetime = 86_400_000
const devicePrefix = 'notify-device:'
const grantPrefix = 'notify-grant:'
const callPrefix = 'notify-call:'

/** Shares the account's synchronous storage, so revocation/deletion wins locally. */
export class AccountNotifications {
    constructor(private readonly storage: DurableObjectStorage) {}
    isCurrent(userID: string): boolean { return this.storage.kv.get('userID') === userID }
    authorized(auth: NotificationAuth): boolean {
        const device = this.storage.kv.get<{ tokenHash: string; expiresAt: number }>(`device:${auth.deviceID}`)
        return this.isCurrent(auth.userID) && !!device && device.expiresAt > Date.now() && device.tokenHash === auth.tokenHash
    }
    register(auth: NotificationAuth, device: NotificationDevice): { previous: NotificationDevice | null } | null {
        if (!this.authorized(auth)) return null
        const previous = this.device(auth.deviceID)
        this.storage.kv.put(devicePrefix + auth.deviceID, device)
        return { previous }
    }
    removeDevice(auth: NotificationAuth): NotificationDevice | null {
        if (!this.authorized(auth)) return null
        const value = this.storage.kv.get<NotificationDevice>(devicePrefix + auth.deviceID) ?? null
        this.storage.kv.delete(devicePrefix + auth.deviceID)
        return value
    }
    device(deviceID: string): NotificationDevice | null { return this.storage.kv.get<NotificationDevice>(devicePrefix + deviceID) ?? null }
    devices(): NotificationDevice[] { return [...this.storage.kv.list<NotificationDevice>({ prefix: devicePrefix })].map(([, value]) => value) }
    takeMutationBudget(auth: NotificationAuth): boolean { return this.authorized(auth) && this.takeBudget('mutation', 60) }
    invalidateDevice(deviceID: string) { this.storage.kv.delete(devicePrefix + deviceID) }
    invalidateAll() {
        for (const prefix of [devicePrefix, grantPrefix, callPrefix, 'notify-rate:']) {
            for (const [key] of this.storage.kv.list({ prefix })) this.storage.kv.delete(key)
        }
    }
    activateGrant(auth: NotificationAuth, hash: string): boolean {
        if (!this.authorized(auth)) return false
        if ([...this.storage.kv.list({ prefix: grantPrefix })].length >= 256) return false
        // Only the opaque hash is stored; the sender appears in the signed capability, not a contact table.
        this.storage.kv.put(grantPrefix + hash, true)
        return true
    }
    revokeGrant(auth: NotificationAuth, hash?: string): boolean {
        if (!this.authorized(auth)) return false
        if (hash) this.storage.kv.delete(grantPrefix + hash)
        else for (const [key] of this.storage.kv.list({ prefix: grantPrefix })) this.storage.kv.delete(key)
        return true
    }
    grantActive(userID: string, hash: string): boolean {
        return this.isCurrent(userID) && this.storage.kv.get(grantPrefix + hash) === true
    }
    takeSendBudget(auth: NotificationAuth): boolean {
        return this.authorized(auth) && this.takeBudget('sender', 60)
    }
    private takeBudget(kind: string, maximum: number): boolean {
        const key = 'notify-rate:' + kind, minute = Math.floor(Date.now() / 60_000)
        const previous = this.storage.kv.get<{ minute: number; count: number }>(key)
        const count = previous?.minute === minute ? previous.count : 0
        if (count >= maximum) return false
        this.storage.kv.put(key, { minute, count: count + 1 })
        return true
    }
    begin(call: NotificationCall): { call: NotificationCall; fresh: boolean } | 'forbidden' | 'limited' {
        this.prune()
        if (!this.grantActive(call.recipientID, call.grantHash)) return 'forbidden'
        const old = this.storage.kv.get<NotificationCall>(callPrefix + call.requestID)
        if (old) return old.sender.userID === call.sender.userID && old.grantHash === call.grantHash ? { call: old, fresh: false } : 'forbidden'
        if (!this.takeBudget('recipient', 20) || [...this.storage.kv.list({ prefix: callPrefix })].length >= 512) return 'limited'
        this.storage.kv.put(callPrefix + call.requestID, call)
        return { call, fresh: true }
    }
    candidates(userID: string, requestID: string): NotificationDevice[] {
        if (!this.liveCall(userID, requestID)) return []
        return [...this.storage.kv.list<NotificationDevice>({ prefix: devicePrefix })].map(([, value]) => value)
            .filter(value => this.authorized({ accountID: '', userID, deviceID: value.deviceID, tokenHash: value.tokenHash }) && value.expiresAt > Date.now()).slice(0, 8)
    }
    liveCall(userID: string, requestID: string): NotificationCall | null {
        const call = this.storage.kv.get<NotificationCall>(callPrefix + requestID)
        return call && call.expiresAt > Date.now() && call.status !== 'cancelled'
            && this.grantActive(userID, call.grantHash) ? call : null
    }
    deliveryCurrent(userID: string, requestID: string, deviceID: string, registrationID: string): boolean {
        return this.candidates(userID, requestID).some(value => value.deviceID === deviceID && value.registrationID === registrationID)
    }
    finish(userID: string, requestID: string, status: DeliveryStatus): void {
        const call = this.liveCall(userID, requestID)
        if (call?.status === 'processing') this.storage.kv.put(callPrefix + requestID, { ...call, status })
    }
    invalidToken(userID: string, deviceID: string, registrationID: string): void {
        if (!this.isCurrent(userID)) return
        const current = this.storage.kv.get<NotificationDevice>(devicePrefix + deviceID)
        if (current?.registrationID === registrationID) this.storage.kv.delete(devicePrefix + deviceID)
    }
    get(userID: string, requestID: string): NotificationCall | null {
        return this.isCurrent(userID) ? this.storage.kv.get<NotificationCall>(callPrefix + requestID) ?? null : null
    }
    cancel(userID: string, requestID: string, senderID: string): boolean {
        const call = this.get(userID, requestID)
        if (!call || call.sender.userID !== senderID) return false
        this.storage.kv.put(callPrefix + requestID, { ...call, status: 'cancelled' })
        return true
    }
    prune() {
        for (const [key, value] of this.storage.kv.list<NotificationCall>({ prefix: callPrefix })) if (value.forgetAt <= Date.now()) this.storage.kv.delete(key)
        for (const [key, value] of this.storage.kv.list<NotificationDevice>({ prefix: devicePrefix })) if (value.expiresAt <= Date.now()) this.storage.kv.delete(key)
    }
    deadlines(): number[] {
        return [...this.storage.kv.list<NotificationCall>({ prefix: callPrefix })].map(([, value]) => value.forgetAt)
    }
}
