
import { isFiveM } from '@/core/nui';
import { apiCall } from '@/core/api';
import { t } from '@/i18n';
import { readJson, writeJson } from '@/lib/storage';
import { formatListDate } from '@/lib/time';

const STORAGE_KEY = 'sd-phone:notes:v1';

export interface Note {
    id:        string;
    body:      string;
    sketches:  string[];
    images?:   string[];
    sketchCount?: number;
    imageCount?:  number;
    loaded?:      boolean;
    createdAt: string;
    updatedAt: string;
}

export interface NotesState {
    notes: Note[];
}

const empty: NotesState = { notes: [] };

export function loadState(): NotesState {
    const raw = readJson<Partial<NotesState>>(STORAGE_KEY);
    return raw ? { notes: Array.isArray(raw.notes) ? raw.notes : [] } : empty;
}

export function saveState(s: NotesState): void {
    writeJson(STORAGE_KEY, s);
}

export { newId } from '@/lib/format';


export function noteTitle(n: Note): string {
    const firstLine = n.body.split('\n').find(l => l.trim().length > 0);
    if (firstLine) return firstLine.trim();
    if ((n.sketchCount ?? n.sketches.length) > 0) return t('notes.sketchTitle', 'Sketch');
    return t('notes.newNote', 'New Note');
}

export function notePreview(n: Note): string {
    const lines = n.body.split('\n').map(l => l.trim()).filter(l => l.length > 0);
    const rest  = lines.slice(1).join(' ').trim();
    if (rest) return rest;
    const imgs = n.imageCount ?? n.images?.length ?? 0;
    const sk   = n.sketchCount ?? n.sketches.length;
    const bits: string[] = [];
    if (imgs) bits.push(imgs === 1 ? t('notes.imageOne', '{n} image', { n: imgs }) : t('notes.imageMany', '{n} images', { n: imgs }));
    if (sk)   bits.push(sk === 1 ? t('notes.drawingOne', '{n} drawing', { n: sk }) : t('notes.drawingMany', '{n} drawings', { n: sk }));
    if (bits.length) return bits.join(' · ');
    return t('notes.noAdditionalText', 'No additional text');
}

export function noteHasContent(n: Note): boolean {
    return n.body.trim().length > 0 || n.sketches.length > 0 || (n.images?.length ?? 0) > 0;
}

export function splitTitle(body: string): { title: string; rest: string } {
    const nl = body.indexOf('\n');
    if (nl === -1) return { title: body, rest: '' };
    return { title: body.slice(0, nl), rest: body.slice(nl + 1) };
}

export function joinTitle(title: string, rest: string): string {
    return rest ? `${title}\n${rest}` : title;
}

export function formatRelativeDate(iso: string): string {
    return formatListDate(iso);
}

export function formatLastEdited(iso: string): string {
    const d   = new Date(iso);
    const now = new Date();
    const hm  = `${d.getHours()}:${String(d.getMinutes()).padStart(2, '0')}`;
    if (d.toDateString() === now.toDateString()) return hm;
    return `${d.getMonth() + 1}/${d.getDate()}/${String(d.getFullYear()).slice(2)}, ${hm}`;
}


export async function shareNote(
    note: Pick<Note, 'body' | 'sketches' | 'images'>,
    target: number,
): Promise<boolean> {
    if (!isFiveM) return true;
    const r = await apiCall<void>('sd-phone:notes:share', {
        target,
        body:     note.body,
        sketches: note.sketches,
        images:   note.images ?? [],
    });
    return r.success;
}
