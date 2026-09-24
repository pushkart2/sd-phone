import { apiData } from '@/core/api';

export interface ContactHit { id: string; name: string; phone: string; avatar?: string; color?: string }
export interface MessageHit { conversationId: string; groupName?: string; snippet: string }
export interface MailHit { id: string; accountId: string; folder: string; subject: string; fromName: string; snippet: string }
export interface NoteHit { id: string; title: string; snippet: string }
export interface GenericHit { id: string; title: string; subtitle?: string; extra?: string }

export interface RemoteResults {
    contacts:    ContactHit[];
    messages:    MessageHit[];
    mail:        MailHit[];
    notes:       NoteHit[];
    calendar:    GenericHit[];
    documents:   GenericHit[];
    recents:     GenericHit[];
    voicememos:  GenericHit[];
    garages:     GenericHit[];
    homes:       GenericHit[];
    places:      GenericHit[];
    weazelnews:  GenericHit[];
    pages:       GenericHit[];
    birdy:       GenericHit[];
    photogram:   GenericHit[];
}

export type SearchSource = keyof RemoteResults;

export const SOURCE_APP: Record<SearchSource, string> = {
    contacts:    'phone',
    messages:    'messages',
    mail:        'mail',
    notes:       'notes',
    calendar:    'calendar',
    documents:   'documents',
    recents:     'phone',
    voicememos:  'voicememos',
    garages:     'garages',
    homes:       'homes',
    places:      'maps',
    weazelnews:  'weazelnews',
    pages:       'pages',
    birdy:       'birdy',
    photogram:   'photogram',
};

function list<T>(v: T[] | undefined): T[] {
    return Array.isArray(v) ? v : [];
}

export async function searchRemote(q: string, sources: SearchSource[]): Promise<RemoteResults | null> {
    if (sources.length === 0) return null;
    const data = await apiData<Partial<RemoteResults>>('sd-phone:search:query', { q, sources });
    if (!data) return null;
    return {
        contacts:    list(data.contacts),
        messages:    list(data.messages),
        mail:        list(data.mail),
        notes:       list(data.notes),
        calendar:    list(data.calendar),
        documents:   list(data.documents),
        recents:     list(data.recents),
        voicememos:  list(data.voicememos),
        garages:     list(data.garages),
        homes:       list(data.homes),
        places:      list(data.places),
        weazelnews:  list(data.weazelnews),
        pages:       list(data.pages),
        birdy:       list(data.birdy),
        photogram:   list(data.photogram),
    };
}
