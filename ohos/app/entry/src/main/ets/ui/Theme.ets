// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// R-06 v1.3 §8：启动器唯一视觉数值来源；材质只从这里取。
import { uiMaterial } from '@kit.ArkUI';

export class C {
  static readonly base: string = '#0B0B0F';
  static readonly elevated: string = '#16161C';
  static readonly elevated2: string = '#1E1E26';
  static readonly scrim: string = '#99000000';
  static readonly primary: string = '#F5F5F7';
  static readonly secondary: string = '#A1A1AA';
  static readonly tertiary: string = '#71717A';
  static readonly inverse: string = '#0B0B0F';
  static readonly accent: string = '#6C8CFF';
  static readonly accentPressed: string = '#5A78E0';
  static readonly danger: string = '#FF453A';
  static readonly error: string = '#FFB4A8';
  static readonly success: string = '#32D74B';
  static readonly separator: string = '#14FFFFFF';
  static readonly glassTint: string = '#14FFFFFF';
  static readonly glassStroke: string = '#24FFFFFF';
}

export class R {
  static readonly xs: number = 4;
  static readonly sm: number = 8;
  static readonly md: number = 12;
  static readonly lg: number = 16;
  static readonly xl: number = 24;
  static readonly pill: number = 999;
}

export class L {
  static readonly header: number = 56;
  static readonly row: number = 56;
  static readonly cta: number = 48;
  static readonly target: number = 44;
  static readonly card: number = 96;
  static readonly peek: number = 16;
  static readonly gridMin: number = 152;
}

export class M {
  static readonly fast: number = 160;
  static readonly base: number = 240;
  static readonly slow: number = 360;
}

class MaterialProbe {
  supported: boolean = false;
  level: number = -1;
  state: number = -1;
}

function probe(): MaterialProbe {
  const p = new MaterialProbe();
  try {
    p.supported = uiMaterial.isImmersiveMaterialSupported();
    p.state = uiMaterial.getMaterialInfo().state;
    p.level = uiMaterial.getGlobalMaterialLevel();
  } catch (error) {
    p.supported = false;
  }
  console.info('S2Arm material supported=' + p.supported.toString() + ' state=' + p.state.toString() +
    ' level=' + p.level.toString());
  return p;
}

const PROBE: MaterialProbe = probe();
// §1.3.5：支持、未被关闭、且不是 SMOOTH 档才开沉浸光感；否则走组件级模糊。
export const IMMERSIVE: boolean = PROBE.supported && PROBE.state !== uiMaterial.MaterialState.DISABLE &&
  PROBE.level !== uiMaterial.MaterialLevel.SMOOTH;
export const MATERIAL_LEVEL: number = PROBE.level;

function make(style: uiMaterial.ImmersiveStyle, color: string, interactive: boolean, shadow: boolean,
  light: string): uiMaterial.ImmersiveMaterial | undefined {
  if (!IMMERSIVE) return undefined;
  return new uiMaterial.ImmersiveMaterial({
    style: style, materialColor: color, interactive: interactive, applyShadow: shadow, colorInvert: false,
    lightEffect: { color: light }
  });
}

export class Glass {
  // 悬浮底栏、标题栏
  static readonly bar: uiMaterial.ImmersiveMaterial | undefined =
    make(uiMaterial.ImmersiveStyle.THIN, '#1A2A2F3A', true, true, '#E6F0FF');
  // Sheet、菜单
  static readonly sheet: uiMaterial.ImmersiveMaterial | undefined =
    make(uiMaterial.ImmersiveStyle.THICK, '#2E14161C', false, true, '#E6F0FF');
  // 卡片上的浮动条、小控件
  static readonly chip: uiMaterial.ImmersiveMaterial | undefined =
    make(uiMaterial.ImmersiveStyle.ULTRA_THIN, '#1AFFFFFF', true, false, '#F0F4FF');
  // 虚拟手柄按键（用户 2026-11-09 授权局内按键用材质）
  static readonly pad: uiMaterial.ImmersiveMaterial | undefined =
    make(uiMaterial.ImmersiveStyle.ULTRA_THIN, '#0AFFFFFF', false, false, '#E0F4FF');
  static readonly padPressed: uiMaterial.ImmersiveMaterial | undefined =
    make(uiMaterial.ImmersiveStyle.THIN, '#336C8CFF', false, false, '#C8D6FF');
  // 局内菜单
  static readonly menu: uiMaterial.ImmersiveMaterial | undefined =
    make(uiMaterial.ImmersiveStyle.REGULAR, '#4014161C', false, true, '#E6F0FF');
}
