// F01 geometry stays portable. Visual preferences are a separate OHOS profile.
import { str } from '../ui/Strings';

export interface PadButton { id: string; x: number; y: number; width: number; height: number; cornerRadius: number; }
export interface PadRegion { x: number; y: number; width: number; height: number; }
export interface PadStick { id: string; activation: PadRegion; radius: number; }
export interface PadLayout { schemaVersion: number; id: string; name: string; buttons: PadButton[]; sticks: PadStick[]; }
export interface ButtonLook { id: string; label: string; icon: string; }
export interface TouchProfile { schema: string; layout: PadLayout; opacity: number; looks: ButtonLook[]; skin?: string; deadzone?: number; }
export interface PadContact { pointer: number; control: string; originX: number; originY: number; x: number; y: number; }
export interface PadState { buttons: number; lx: number; ly: number; rx: number; ry: number; }
export const BUTTON_IDS: string[] = ['A', 'B', 'X', 'Y', 'LS', 'RS', 'L', 'R', 'ZL', 'ZR', 'PLUS', 'MINUS', 'LEFT', 'UP', 'RIGHT', 'DOWN'];
// Stored icon identifiers (saved profiles use them); ICON_NAMES holds the displayed names in the same order.
export const ICONS: string[] = ['字母', '攻击', '跳跃', '冲刺', '技能', '背包'];
export const ICON_NAMES: Resource[] = [$r('app.string.icon_letter'), $r('app.string.icon_attack'), $r('app.string.icon_jump'),
  $r('app.string.icon_dash'), $r('app.string.icon_skill'), $r('app.string.icon_bag')];
export const PRESET_NAMES: Resource[] = [$r('app.string.preset_handheld'), $r('app.string.preset_explore'),
  $r('app.string.preset_combat'), $r('app.string.preset_menu')];

function button(id: string, x: number, y: number, size: number = 0.13): PadButton {
  return { id: id, x: x, y: y, width: size, height: size, cornerRadius: size / 2 };
}
export function defaultProfile(): TouchProfile {
  // 0.6：右手菱形 ABXY、肩键胶囊、十字键贴左摇杆右下；摇杆浮动（按下处即圆心）。
  return { schema: 's2a.ohos.touch-profile.v1', opacity: 0.8, looks: [], skin: 'console', deadzone: 0.08, layout: {
    schemaVersion: 1, id: 'ohos-console', name: str(PRESET_NAMES[0]), buttons: [
      button('A', 0.935, 0.62, 0.135), button('B', 0.865, 0.80, 0.135),
      button('X', 0.865, 0.44, 0.135), button('Y', 0.795, 0.62, 0.135),
      button('LS', 0.265, 0.92, 0.075), button('RS', 0.735, 0.92, 0.075),
      { id:'ZL',x:0.07,y:0.13,width:0.17,height:0.08,cornerRadius:0.04 },
      { id:'L',x:0.19,y:0.13,width:0.17,height:0.08,cornerRadius:0.04 },
      { id:'R',x:0.81,y:0.13,width:0.17,height:0.08,cornerRadius:0.04 },
      { id:'ZR',x:0.93,y:0.13,width:0.17,height:0.08,cornerRadius:0.04 },
      button('MINUS', 0.44, 0.10, 0.07), button('PLUS', 0.56, 0.10, 0.07),
      button('LEFT', 0.29, 0.70, 0.072), button('UP', 0.33, 0.61, 0.072),
      button('RIGHT', 0.37, 0.70, 0.072), button('DOWN', 0.33, 0.79, 0.072)
    ], sticks: [
      { id: 'left', activation: { x: 0.0, y: 0.32, width: 0.25, height: 0.66 }, radius: 0.13 },
      { id: 'right', activation: { x: 0.52, y: 0.42, width: 0.22, height: 0.56 }, radius: 0.11 }
    ]
  } };
}
export function actionProfile(stage: string = 'explore'): TouchProfile {
  const value = defaultProfile();
  value.skin = 'action';
  value.layout.id = 'ohos-action-' + stage;
  value.layout.name = str(PRESET_NAMES[stage === 'menu' ? 3 : stage === 'combat' ? 2 : 1]);
  value.looks = [
    { id: 'A', label: str($r('app.string.action_interact')), icon: '字母' }, { id: 'B', label: str($r('app.string.action_dash')), icon: '字母' },
    { id: 'X', label: str($r('app.string.action_jump')), icon: '字母' }, { id: 'Y', label: str($r('app.string.action_attack')), icon: '字母' },
    { id: 'L', label: str($r('app.string.action_ability')), icon: '字母' }, { id: 'ZL', label: str($r('app.string.action_lock')), icon: '字母' },
    { id: 'R', label: str($r('app.string.action_throw')), icon: '字母' }, { id: 'ZR', label: str($r('app.string.action_aim')), icon: '字母' },
    { id: 'PLUS', label: str($r('app.string.action_bag')), icon: '字母' }, { id: 'MINUS', label: str($r('app.string.action_map')), icon: '字母' },
    { id: 'LS', label: str($r('app.string.action_crouch')), icon: '字母' }, { id: 'RS', label: str($r('app.string.action_scope')), icon: '字母' }
  ];
  value.layout.buttons.forEach((b: PadButton) => {
    if (b.id === 'LS' || b.id === 'RS') { b.width = 0.085; b.height = 0.085; b.cornerRadius = 0.0425; }
  });
  if (stage === 'combat') {
    value.layout.buttons.forEach((b: PadButton) => {
      if (['A', 'B', 'X', 'Y'].indexOf(b.id) >= 0) { b.width = 0.15; b.height = 0.15; b.cornerRadius = 0.075; }
    });
  } else if (stage === 'menu') {
    value.layout.buttons.forEach((b: PadButton) => {
      if (['PLUS', 'MINUS', 'LEFT', 'UP', 'RIGHT', 'DOWN'].indexOf(b.id) >= 0) {
        b.width = 0.10; b.height = 0.10; b.cornerRadius = 0.05;
      }
    });
  }
  return value;
}
export function cloneProfile(value: TouchProfile): TouchProfile { return JSON.parse(JSON.stringify(value)) as TouchProfile; }
function unit(value: number): boolean { return Number.isFinite(value) && value >= 0 && value <= 1; }
export function parseProfile(text: string): TouchProfile {
  if (text.length > 65536) throw new Error(str($r('app.string.layout_too_large')));
  const wrapper = JSON.parse(text) as TouchProfile;
  const value: TouchProfile = wrapper.schema === 's2a.ohos.touch-profile.v1' ? wrapper : {
    schema: 's2a.ohos.touch-profile.v1', layout: JSON.parse(text) as PadLayout, opacity: 0.72, looks: []
  };
  const layout = value.layout;
  if (!layout || layout.schemaVersion !== 1 || !/^[a-z0-9][a-z0-9._-]{0,63}$/.test(layout.id) ||
      typeof layout.name !== 'string' || !layout.name || layout.name.length > 64 || !Array.isArray(layout.buttons) || !Array.isArray(layout.sticks) ||
      layout.buttons.length < 14 || layout.buttons.length > 16 || layout.sticks.length !== 2 ||
      !Number.isFinite(value.opacity) || value.opacity < 0.2 || value.opacity > 1 || !Array.isArray(value.looks)) {
    throw new Error(str($r('app.string.layout_format_invalid')));
  }
  if ((value.skin !== undefined && value.skin !== 'console' && value.skin !== 'action') ||
      (value.deadzone !== undefined && (!Number.isFinite(value.deadzone) || value.deadzone < 0 || value.deadzone > 0.3))) {
    throw new Error(str($r('app.string.layout_theme_invalid')));
  }
  const seen: string[] = [];
  layout.buttons.forEach((b: PadButton) => {
    if (BUTTON_IDS.indexOf(b.id) < 0 || seen.indexOf(b.id) >= 0 || !unit(b.x) || !unit(b.y) ||
        !Number.isFinite(b.width) || b.width < 0.04 || b.width > 0.4 ||
        !Number.isFinite(b.height) || b.height < 0.04 || b.height > 0.4 ||
        !Number.isFinite(b.cornerRadius) || b.cornerRadius < 0 || b.cornerRadius > Math.min(b.width, b.height) / 2) {
      throw new Error(str($r('app.string.layout_button_invalid')));
    }
    seen.push(b.id);
  });
  if (BUTTON_IDS.some((id: string) => id !== 'LS' && id !== 'RS' && seen.indexOf(id) < 0)) throw new Error(str($r('app.string.layout_buttons_missing')));
  const sticks: string[] = [];
  layout.sticks.forEach((s: PadStick) => {
    const r = s.activation;
    if ((s.id !== 'left' && s.id !== 'right') || sticks.indexOf(s.id) >= 0 || !r ||
        !unit(r.x) || !unit(r.y) || !unit(r.width) || !unit(r.height) || r.width === 0 || r.height === 0 ||
        r.x + r.width > 1.001 || r.y + r.height > 1.001 ||
        !Number.isFinite(s.radius) || s.radius < 0.04 || s.radius > 0.3) throw new Error(str($r('app.string.layout_stick_invalid')));
    sticks.push(s.id);
  });
  const a = layout.sticks[0].activation; const b = layout.sticks[1].activation;
  if (a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height) throw new Error(str($r('app.string.layout_sticks_overlap')));
  value.looks.forEach((look: ButtonLook) => {
    if (BUTTON_IDS.indexOf(look.id) < 0 || typeof look.label !== 'string' || look.label.length > 12 || ICONS.indexOf(look.icon) < 0) throw new Error(str($r('app.string.layout_look_invalid')));
  });
  return value;
}
export function buttonBit(id: string): number { const index = BUTTON_IDS.indexOf(id); return index < 0 ? 0 : 1 << index; }
export function stickAxes(dx: number, dy: number, deadzone: number): number[] {
  if (!Number.isFinite(dx) || !Number.isFinite(dy) || !Number.isFinite(deadzone) || deadzone < 0 || deadzone >= 1) return [0, 0];
  const length = Math.sqrt(dx * dx + dy * dy);
  if (length <= deadzone) return [0, 0];
  const magnitude = (Math.min(length, 1) - deadzone) / (1 - deadzone);
  return [Math.round(dx / length * magnitude * 32767), Math.round(dy / length * magnitude * 32767)];
}
export function buttonLabel(id: string): string {
  if (id === 'PLUS') return '+'; if (id === 'MINUS') return '−';
  if (id === 'LEFT') return '◀'; if (id === 'RIGHT') return '▶';
  if (id === 'UP') return '▲'; if (id === 'DOWN') return '▼';
  if (id === 'LS') return 'L3'; if (id === 'RS') return 'R3'; return id;
}
