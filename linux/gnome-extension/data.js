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

const RELEASE_PAGE = 'https://github.com/hotherside/Hotch/releases/tag/';

// The footer's update notice: a newer Linux release, not skipped, while
// automatic checks are on. Only the GitHub release page of that very version
// is ever linked.
export function updateNotice(update, settings) {
    if (!update?.available || !settings.updateChecks || update.latest === settings.updateSkipped)
        return null;
    const version = update.latest;
    const page = [`${RELEASE_PAGE}v${version}`, `${RELEASE_PAGE}${version}`];
    if (typeof version !== 'string' || !/^\d+\.\d+\.\d+$/.test(version) || !page.includes(update.url))
        return null;
    return {version, url: update.url};
}

export function readingStatus(u, now) {
    if (!u.stale)
        return '';
    const minutes = Math.max(0, Math.floor((now - u.fetchedAt) / 60));
    return `Reading ${minutes}m old · Update failed: ${u.error}`;
}
