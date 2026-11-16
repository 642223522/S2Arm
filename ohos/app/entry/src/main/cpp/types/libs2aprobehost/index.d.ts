export interface RuntimeStatus { state: number; phase: number; error: number; servicesError: number; detail: string; finished: boolean; }
export const configure: (language: string, region: string, timezone: string, hz: number, files: string) => string;
export const start: (game: string, state: string, modules: string, names: string, titleId: string) => string;
export const status: () => RuntimeStatus;
export const input: (buttons: number, lx: number, ly: number, rx: number, ry: number) => string;
export const foreground: (active: boolean) => string;
export const stop: () => string;
export interface UiRequest { error: number; id: string; request: string; }
export const uiTake: () => UiRequest;
export const uiReply: (id: string, reply: string) => number;
export const uiCancel: (id: string) => number;
export const displaySettings: (resolutionScale: string, scalingFilter: string, widenMode: string) => string;


export interface ControllerStatus { available: boolean; connected: boolean; name: string; detail: string; }
export const controllerStatus: () => ControllerStatus;
export const inputBlocked: (blocked: boolean) => void;
export const gameFeedback: (enabled: boolean) => string;
export const powerSave: (enabled: boolean) => string;
export const allowTall: (enabled: boolean) => string;
export const stopFeedback: () => void;
export const presentCount: () => number;
