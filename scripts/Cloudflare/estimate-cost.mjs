#!/usr/bin/env node
import { pathToFileURL } from 'node:url';
// USD, decimal GB; official rates checked 2026-10-21. No taxes/FX or negotiated pricing.
export function estimate({ users = 1000, hours = 20, roomSize = 4, wireKbps = 64, speakingFraction = 1,
    paid = true, wsInterval = 0.25, activeMsPerEvent = 5, httpActiveMs = 200, workerCpuMs = 2,
    storedGB = 0.1, kitFreeMinutes = 0 } = {}) {
    for (const value of [users, hours, roomSize, wireKbps, speakingFraction, wsInterval, activeMsPerEvent, httpActiveMs, workerCpuMs, storedGB, kitFreeMinutes]) {
        if (!Number.isFinite(value) || value < 0) throw new Error('Inputs must be finite and nonnegative');
    }
    if (roomSize < 2 || wsInterval === 0 || speakingFraction > 1) throw new Error('Invalid scenario');
    const minutes = users * hours * 60;
    const gb = minutes * 60 * wireKbps * 1000 / 8 * (roomSize - 1) * speakingFraction / 1e9;
    // One-hour calls; five-minute renewal requests, setup/pull/answer/socket/close, and room expiry alarms.
    const calls = users * hours;
    const workerRequests = minutes / 5 + calls * 6;
    const messages = minutes * 60 / wsInterval;
    const doHttp = workerRequests + minutes / 5 + calls * 2;
    const alarms = calls / roomSize;
    const doRequests = doHttp + alarms + messages / 20;
    const eventActiveSeconds = ((doHttp + alarms) * httpActiveMs + messages * activeMsPerEvent) / 1000;
    // Concurrent events in one room cannot multiply its wall-clock occupancy.
    // Add the global guard's HTTP work separately; balanced fixed-size rooms are assumed.
    const occupiedSeconds = minutes * 60 / roomSize + (minutes / 5 + calls * 2) * httpActiveMs / 1000;
    const doGBs = 0.128 * Math.min(eventActiveSeconds, occupiedSeconds);
    // Upper estimate for small KV records on SQLite. Fanout/list operations count each row.
    const reads = doHttp * (roomSize + 2) + messages + alarms * roomSize;
    const writes = (minutes / 5) * 4 + calls * (roomSize + 12);
    const over = (n, included, unit, price) => Math.ceil(Math.max(0, n - included) / unit) * price;
    const costs = {
        realtime: Math.max(0, gb - 1000) * .05,
        workersBase: paid ? 5 : 0,
        workerRequests: paid ? Math.max(0, workerRequests - 1e7) / 1e6 * .30 : 0,
        workerCPU: paid ? Math.max(0, workerRequests * workerCpuMs - 3e7) / 1e6 * .02 : 0,
        doRequests: paid ? over(doRequests, 1e6, 1e6, .15) : 0,
        doDuration: paid ? over(doGBs, 400000, 1e6, 12.50) : 0,
        storageReads: paid ? over(reads, 25e9, 1e6, .001) : 0,
        storageWrites: paid ? over(writes, 50e6, 1e6, 1) : 0,
        storageGB: paid ? Math.max(0, storedGB - 5) * .20 : 0,
    };
    return { users, hours, roomSize, wireKbps, speakingFraction, minutes, gb, workerRequests, doRequests, doGBs, reads, writes,
        costs, total: Object.values(costs).reduce((a,b) => a+b, 0),
        realtimeKitAudio: Math.max(0, minutes - kitFreeMinutes) * .0005,
        freeDailyAverageFits: workerRequests / 30 <= 100000 && doRequests / 30 <= 100000 && doGBs / 30 <= 13000 && reads / 30 <= 5e6 && writes / 30 <= 100000 && storedGB <= 5,
        marginalBreakEvenRoomSize: 1 + .0005 / (60 * wireKbps * 1000 / 8 / 1e9 * .05 * speakingFraction) };
}
if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
    if (process.argv[2]) console.log(JSON.stringify(estimate(JSON.parse(process.argv[2])), null, 2));
    else {
        console.log('users\thours/user\troom\tGB\tSFU+control USD\tRealtimeKit audio USD');
        for (const users of [4,100,1000,10000]) for (const roomSize of [2,4,8]) {
            if (roomSize > users) continue;
            const r = estimate({ users, roomSize, paid: users !== 4 });
            console.log([users,20,roomSize,r.gb.toFixed(2),r.total.toFixed(2),r.realtimeKitAudio.toFixed(2)].join('\t'));
        }
    }
}
