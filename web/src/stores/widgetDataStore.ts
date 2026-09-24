import { create } from 'zustand';

import type { BankTx } from '@/apps/banking/bankingApi';
import type { Vehicle } from '@/apps/garages/data';
import type { Article } from '@/apps/weazelnews/data';
import type { HealthPayload, WeatherPayload } from '@/core/types';

const num = (v: unknown): number | null =>
    (typeof v === 'number' && Number.isFinite(v) ? v : null);

interface WidgetDataState {
    weather: WeatherPayload | null;
    balance: number | null;
    cash: number | null;
    transactions: BankTx[];
    health: HealthPayload | null;
    vehicles: Vehicle[];
    articles: Article[];
    ticker: string[];
    setWeather: (w: WeatherPayload | null) => void;
    setWallet: (balance: number | null, cash: number | null, transactions: BankTx[]) => void;
    setHealth: (h: HealthPayload | null) => void;
    setVehicles: (v: Vehicle[]) => void;
    setNews: (articles: Article[], ticker: string[]) => void;
}

export const useWidgetData = create<WidgetDataState>((set) => ({
    weather: null,
    balance: null,
    cash: null,
    transactions: [],
    health: null,
    vehicles: [],
    articles: [],
    ticker: [],
    setWeather: (weather) => set({ weather }),
    setWallet: (balance, cash, transactions) => set({
        balance: num(balance),
        cash: num(cash),
        transactions: Array.isArray(transactions) ? transactions.slice(0, 16) : [],
    }),
    setHealth: (health) => set({ health }),
    setVehicles: (vehicles) => set({ vehicles: Array.isArray(vehicles) ? vehicles.slice(0, 12) : [] }),
    setNews: (articles, ticker) => set({
        articles: Array.isArray(articles) ? articles.slice(0, 6) : [],
        ticker: Array.isArray(ticker) ? ticker.slice(0, 8) : [],
    }),
}));
