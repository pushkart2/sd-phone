import type { ReactNode } from 'react';

import { t } from '@/i18n';
import { requestOpenAt, requestOpenMaps } from '@/shell/deeplink';
import type { GenericHit, SearchSource } from './spotlightApi';

export const RISE = 'animate-[spotlight-rise_280ms_cubic-bezier(0.32,0.72,0,1)_both]';

export const CARD = 'overflow-hidden rounded-[14px] bg-elevated/85 shadow-[0_1px_3px_rgba(0,0,0,0.08)] dark:bg-elevated/75';

export function riseDelay(index: number): { animationDelay: string } {
    return { animationDelay: `${index * 35}ms` };
}

export function Section({ title, children }: { title: string; children: ReactNode }) {
    return (
        <section className={`mb-5 ${RISE}`}>
            <h2 className="mb-2 px-1 text-[20px] font-bold text-label">{title}</h2>
            {children}
        </section>
    );
}

export function Row({ icon, title, subtitle, onPress, divider, index, action }: { icon: ReactNode; title: string; subtitle?: string; onPress: () => void; divider: boolean; index: number; action?: ReactNode }) {
    return (
        <button
            type="button"
            onClick={onPress}
            className={`relative flex w-full items-center gap-3.5 px-4 py-2.5 text-start active:bg-black/5 dark:active:bg-white/5 ${RISE}`}
            style={riseDelay(index)}
        >
            <span className="flex h-[40px] w-[40px] shrink-0 items-center justify-center">{icon}</span>
            <span className="flex min-w-0 flex-1 flex-col justify-center">
                <span className="truncate text-[17px] leading-snug text-label">{title}</span>
                {subtitle && <span className="mt-0.5 truncate text-[15px] leading-snug text-ios-gray">{subtitle}</span>}
            </span>
            {action}
            {divider && <span className="pointer-events-none absolute inset-x-0 bottom-0 h-px bg-hairline/10" />}
        </button>
    );
}

export type GenericKey = Exclude<SearchSource, 'contacts' | 'messages' | 'mail' | 'notes'> | 'music';

export interface SectionDef {
    key:    GenericKey;
    title:  () => string;
    appId:  string;
    masked?: boolean;
    open:   (hit: GenericHit) => void;
}

function openPlace(hit: GenericHit): void {
    const [x, y] = (hit.extra ?? '').split(',').map(Number);
    if (Number.isFinite(x) && Number.isFinite(y)) requestOpenMaps({ label: hit.title, x, y, companyId: hit.id });
    else requestOpenMaps(null);
}

export const SECTIONS: SectionDef[] = [
    { key: 'calendar', title: () => t('spotlight.calendar', 'Calendar'), appId: 'calendar', open: hit => requestOpenAt({ app: 'calendar', date: hit.extra ?? '', eventId: hit.id }) },
    { key: 'documents', title: () => t('spotlight.documents', 'Files'), appId: 'documents', open: hit => requestOpenAt({ app: 'documents', docId: hit.id }) },
    { key: 'recents', title: () => t('spotlight.recents', 'Recents'), appId: 'phone', masked: true, open: () => requestOpenAt({ app: 'phone', tab: 'recents' }) },
    { key: 'voicememos', title: () => t('spotlight.voicememos', 'Voice Memos'), appId: 'voicememos', open: hit => requestOpenAt({ app: 'voicememos', memoId: hit.id }) },
    { key: 'music', title: () => t('spotlight.music', 'Music'), appId: 'music', open: hit => requestOpenAt(hit.extra === 'playlist' ? { app: 'music', playlistId: hit.id } : { app: 'music', songId: hit.id }) },
    { key: 'garages', title: () => t('spotlight.garages', 'Garages'), appId: 'garages', open: hit => requestOpenAt({ app: 'garages', vehicleId: hit.id }) },
    { key: 'homes', title: () => t('spotlight.homes', 'Homes'), appId: 'homes', open: hit => requestOpenAt({ app: 'homes', homeId: hit.id }) },
    { key: 'places', title: () => t('spotlight.places', 'Places'), appId: 'maps', open: openPlace },
    { key: 'weazelnews', title: () => t('spotlight.weazelnews', 'Weazel News'), appId: 'weazelnews', open: hit => requestOpenAt({ app: 'weazelnews', articleId: hit.id }) },
    { key: 'marketplace', title: () => t('spotlight.marketplace', 'Marketplace'), appId: 'marketplace', open: hit => requestOpenAt({ app: 'marketplace', listingId: hit.id }) },
    { key: 'pages', title: () => t('spotlight.pages', 'Pages'), appId: 'pages', open: hit => requestOpenAt({ app: 'pages', postId: hit.id }) },
    { key: 'birdy', title: () => t('spotlight.birdy', 'Birdy'), appId: 'birdy', open: hit => requestOpenAt({ app: 'birdy', handle: hit.id }) },
    { key: 'photogram', title: () => t('spotlight.photogram', 'Photogram'), appId: 'photogram', open: hit => requestOpenAt({ app: 'photogram', handle: hit.id }) },
];
