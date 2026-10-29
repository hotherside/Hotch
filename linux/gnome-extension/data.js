// Shared, GI-free data policy so failure handling can be regression-tested.
export const MAX_USAGE_AGE = 2 * 60 * 60;

export function mergeUsage(fresh, previous, now) {
    return fresh.map(u => {
        if (u.windows.length || !u.error)
            return u;
        const old = previous.find(o => o.provider === u.provider);
        if (old?.windows.length && Number.isFinite(old.fetchedAt) && now - old.fetchedAt < MAX_USAGE_AGE)
            return {...old, error: u.error, stale: true};
        return u;
    });
}

export function readingStatus(u, now) {
    if (!u.stale)
        return '';
    const minutes = Math.max(0, Math.floor((now - u.fetchedAt) / 60));
    return `Reading ${minutes}m old · Update failed: ${u.error}`;
}
