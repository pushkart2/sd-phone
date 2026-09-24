import { useEffect, useLayoutEffect, useRef } from 'react';

import { create } from 'zustand';

import type { SettingsPage } from '@/apps/settings/data';

export type AppTarget =
    | { app: 'settings'; page: SettingsPage | null }
    | { app: 'phone'; contactId: string }
    | { app: 'phone'; tab: 'recents' }
    | { app: 'notes'; noteId: string }
    | { app: 'messages'; conversationId: string }
    | { app: 'calendar'; date: string; eventId: string }
    | { app: 'documents'; docId: string }
    | { app: 'voicememos'; memoId: string }
    | { app: 'garages'; vehicleId: string }
    | { app: 'homes'; homeId: string }
    | { app: 'weazelnews'; articleId: string }
    | { app: 'pages'; postId: string }
    | { app: 'birdy'; handle: string }
    | { app: 'photogram'; handle: string }
    | { app: 'music'; songId?: string; playlistId?: string }
    | { app: 'appstore'; appId: string };

type TargetApp = AppTarget['app'];
type TargetFor<A extends TargetApp> = Extract<AppTarget, { app: A }>;

export interface MapsTarget {
    label: string;
    x:     number;
    y:     number;
    icon?: string;
    color?: string;
    companyId?: string;
}

export interface MessagesTarget {
    number: string;
    name?:  string;
}

export interface MailTarget {
    to?: string;
    message?: { folder: string; msgId: string; accountId?: string };
}

interface DeeplinkState {
    mapsNonce:      number;
    mapsTarget:     MapsTarget | null;
    messagesNonce:  number;
    messagesTarget: MessagesTarget | null;
    mailNonce:      number;
    mailTarget:     MailTarget | null;
    targets:        Partial<Record<TargetApp, AppTarget>>;
    targetNonce:    number;
    targetApp:      TargetApp | null;
}

const useDeeplinkStore = create<DeeplinkState>(() => ({
    mapsNonce: 0,     mapsTarget: null,
    messagesNonce: 0, messagesTarget: null,
    mailNonce: 0,     mailTarget: null,
    targets: {}, targetNonce: 0, targetApp: null,
}));

export function requestOpenMaps(target?: MapsTarget | null): void {
    useDeeplinkStore.setState(s => ({ mapsTarget: target ?? null, mapsNonce: s.mapsNonce + 1 }));
}

export function takeMapsTarget(): MapsTarget | null {
    const t = useDeeplinkStore.getState().mapsTarget;
    useDeeplinkStore.setState({ mapsTarget: null });
    return t;
}

export function onOpenMaps(handler: () => void): () => void {
    return useDeeplinkStore.subscribe((s, prev) => { if (s.mapsNonce !== prev.mapsNonce) handler(); });
}

export function requestOpenMessages(target: MessagesTarget): void {
    useDeeplinkStore.setState(s => ({ messagesTarget: target, messagesNonce: s.messagesNonce + 1 }));
}

export function peekMessagesTarget(): MessagesTarget | null {
    return useDeeplinkStore.getState().messagesTarget;
}

export function clearMessagesTarget(): void {
    useDeeplinkStore.setState({ messagesTarget: null });
}

export function onOpenMessages(handler: () => void): () => void {
    return useDeeplinkStore.subscribe((s, prev) => { if (s.messagesNonce !== prev.messagesNonce) handler(); });
}

export function requestOpenMail(target: MailTarget): void {
    useDeeplinkStore.setState(s => ({ mailTarget: target, mailNonce: s.mailNonce + 1 }));
}

export function takeMailTarget(): MailTarget | null {
    const t = useDeeplinkStore.getState().mailTarget;
    useDeeplinkStore.setState({ mailTarget: null });
    return t;
}

export function onOpenMail(handler: () => void): () => void {
    return useDeeplinkStore.subscribe((s, prev) => { if (s.mailNonce !== prev.mailNonce) handler(); });
}

export function requestOpenAt(target: AppTarget): void {
    useDeeplinkStore.setState(s => ({
        targets:     { ...s.targets, [target.app]: target },
        targetNonce: s.targetNonce + 1,
        targetApp:   target.app,
    }));
}

export function takeTarget<A extends TargetApp>(app: A): TargetFor<A> | null {
    const found = useDeeplinkStore.getState().targets[app] as TargetFor<A> | undefined;
    if (!found) return null;
    useDeeplinkStore.setState(s => {
        const next = { ...s.targets };
        delete next[app];
        return { targets: next };
    });
    return found;
}

export function onOpenAt(handler: (app: TargetApp) => void): () => void {
    return useDeeplinkStore.subscribe((s, prev) => {
        if (s.targetNonce !== prev.targetNonce && s.targetApp) handler(s.targetApp);
    });
}

export function useDeeplinkTarget<A extends TargetApp>(app: A, apply: (target: TargetFor<A>) => void): void {
    const applyRef = useRef(apply);
    useEffect(() => { applyRef.current = apply; });
    useLayoutEffect(() => {
        const run = () => {
            const found = takeTarget(app);
            if (found) applyRef.current(found);
        };
        run();
        return useDeeplinkStore.subscribe((s, prev) => {
            if (s.targetNonce !== prev.targetNonce && s.targetApp === app) run();
        });
    }, [app]);
}
