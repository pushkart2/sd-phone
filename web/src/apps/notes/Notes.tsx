import { useCallback, useEffect, useRef, useState } from 'react';

import { fetchNui, isFiveM } from '@/core/nui';
import { apiCall } from '@/core/api';
import { useDidEnter } from '@/hooks/useDidEnter';
import { useNuiEvent } from '@/hooks/useNuiEvent';
import { useNuiQuery } from '@/hooks/useNuiQuery';
import { useSessionState } from '@/hooks/useSessionState';
import { loadState, newId, saveState, noteHasContent } from './data';
import type { Note, NotesState } from './data';
import { NoteEditor } from './NoteEditor';
import { NotesList } from './NotesList';
import { t } from '@/i18n';
import { useDeeplinkTarget } from '@/shell/deeplink';

export function Notes({ onClose }: { onClose: () => void }) {
    const [state, setState] = useState<NotesState>(() => (isFiveM ? { notes: [] } : loadState()));
    const [openId, setOpenId] = useSessionState<string | null>('notes:openNoteId', null);
    const [pendingNoteId, setPendingNoteId] = useState<string | null>(null);
    useDeeplinkTarget('notes', target => setPendingNoteId(target.noteId));
    useEffect(() => {
        if (!pendingNoteId || !state.notes.some(n => n.id === pendingNoteId)) return;
        setOpenId(pendingNoteId);
        setPendingNoteId(null);
    }, [pendingNoteId, state.notes, setOpenId]);
    const loadingNotes = useRef(new Set<string>());

    useNuiQuery<NotesState>('sd-phone:notes:list', { enabled: isFiveM, onData: setState });

    useNuiEvent('sd-phone:notes:added', useCallback((note: Note) => {
        setState(prev => prev.notes.some(n => n.id === note.id)
            ? prev
            : { notes: [note, ...prev.notes] });
    }, []));

    const commit = useCallback((next: NotesState) => {
        setState(next);
        if (!isFiveM) saveState(next);
    }, []);

    const saveNote   = useCallback((n: Note) => { if (isFiveM) void fetchNui('sd-phone:notes:save', n); }, []);
    const removeNote = useCallback((id: string) => { if (isFiveM) void fetchNui('sd-phone:notes:delete', { id }); }, []);

    function createNote() {
        const now = new Date().toISOString();
        const n: Note = {
            id:        newId(),
            body:      '',
            sketches:  [],
            images:    [],
            loaded:    true,
            createdAt: now,
            updatedAt: now,
        };
        commit({ notes: [n, ...state.notes] });
        saveNote(n);
        setOpenId(n.id);
    }

    function deleteNote(id: string) {
        commit({ notes: state.notes.filter(n => n.id !== id) });
        removeNote(id);
        if (openId === id) setOpenId(null);
    }

    function updateNote(next: Note) {
        commit({ notes: state.notes.map(n => n.id === next.id ? next : n) });
        saveNote(next);
    }

    function closeEditor() {
        if (openId) {
            const n = state.notes.find(x => x.id === openId);
            if (n && !noteHasContent(n)) {
                deleteNote(openId);
                return;
            }
        }
        setOpenId(null);
    }

    const openNote = useCallback(async (id: string) => {
        let note = state.notes.find(n => n.id === id);
        if (!note) return;
        if (note.loaded === false && isFiveM) {
            if (loadingNotes.current.has(id)) return;
            loadingNotes.current.add(id);
            try {
                const res = await apiCall<{ note: Note }>('sd-phone:notes:get', { id });
                if (!res.success || !res.data) return;
                note = res.data.note;
                setState(prev => ({ notes: prev.notes.map(n => n.id === id ? note! : n) }));
            } finally {
                loadingNotes.current.delete(id);
            }
        }
        setOpenId(id);
    }, [setOpenId, state.notes]);

    // Session state can restore an editor before the summary query arrives. Hydrate it once the
    // matching summary becomes available instead of leaving a blank editor behind the list.
    useEffect(() => {
        if (openId && state.notes.some(n => n.id === openId && n.loaded === false)) {
            void openNote(openId);
        }
    }, [openId, openNote, state.notes]);

    const open = openId ? state.notes.find(n => n.id === openId && n.loaded !== false) : null;

    const animateNav = useDidEnter();

    return (
        <div className="absolute inset-0 z-10 overflow-hidden bg-[#fbf9f3] dark:bg-base">
            <NotesList
                notes={state.notes}
                onOpen={id => { void openNote(id); }}
                onCompose={createNote}
            />
            {open && (
                <NoteEditor
                    note={open}
                    onBack={closeEditor}
                    onChange={updateNote}
                    onDelete={() => deleteNote(open.id)}
                    animateIn={animateNav}
                />
            )}
            <button
                type="button"
                onClick={onClose}
                aria-label={t('notes.closeNotes', 'Close Notes')}
                className="absolute inset-x-0 bottom-0 z-50 h-7 cursor-default"
            />
        </div>
    );
}
