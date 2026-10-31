import { DurableObject } from 'cloudflare:workers'
import type { Env } from './types'

export interface NotificationBinding {
    accountID: string; userID: string; expiresAt: number
    deviceID?: string; registrationID?: string
}

/** One opaque public-ID or token-hash index per object, never an address book. */
export class NotificationIndex extends DurableObject<Env> {
    async bind(value: NotificationBinding): Promise<void> {
        const current = this.current()
        // Public routing must last while any registered credential can use it.
        // Token bindings retain latest-owner semantics, even with an earlier expiry.
        if (current && current.registrationID === undefined && value.registrationID === undefined
            && current.accountID === value.accountID && current.userID === value.userID) {
            value = { ...value, expiresAt: Math.max(current.expiresAt, value.expiresAt) }
        }
        this.ctx.storage.kv.put('binding', value)
        await this.ctx.storage.setAlarm(value.expiresAt)
    }
    current(): NotificationBinding | null {
        const value = this.ctx.storage.kv.get<NotificationBinding>('binding')
        return value && value.expiresAt > Date.now() ? value : null
    }
    async remove(accountID: string, userID: string, registrationID?: string): Promise<void> {
        const value = this.current()
        if (value?.accountID !== accountID || value.userID !== userID || value.registrationID !== registrationID) return
        await this.ctx.storage.deleteAll()
    }
    async alarm(): Promise<void> {
        const value = this.current()
        if (value) await this.ctx.storage.setAlarm(value.expiresAt)
        else await this.ctx.storage.deleteAll()
    }
}
