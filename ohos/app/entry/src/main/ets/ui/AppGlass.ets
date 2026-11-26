import { uiMaterial } from '@kit.ArkUI';

function supported(): boolean {
  try {
    const enabled = uiMaterial.isImmersiveMaterialSupported();
    const info = uiMaterial.getMaterialInfo();
    console.info('S2Arm material supported=' + enabled.toString() + ' level=' +
      uiMaterial.getGlobalMaterialLevel().toString() + ' appState=' + info.state.toString());
    return enabled && info.state !== uiMaterial.MaterialState.DISABLE;
  } catch (error) { console.info('S2Arm material capability unavailable; native blur fallback'); return false; }
}
export const USE_IMMERSIVE: boolean = supported();
function glass(style: uiMaterial.ImmersiveStyle, color: string, interactive: boolean): uiMaterial.Material | undefined {
  return USE_IMMERSIVE ? new uiMaterial.ImmersiveMaterial({
    style: style, materialColor: color, applyShadow: true, interactive: interactive,
    colorInvert: false, lightEffect: { color: '#E0F4D4' }
  }) : undefined;
}
export const PANEL_GLASS: uiMaterial.Material | undefined = glass(uiMaterial.ImmersiveStyle.REGULAR, '#0B8AA798', false);
export const CONTROL_GLASS: uiMaterial.Material | undefined = glass(uiMaterial.ImmersiveStyle.THIN, '#1086B39C', true);
export const SELECTED_GLASS: uiMaterial.Material | undefined = glass(uiMaterial.ImmersiveStyle.THIN, '#24A3C9B0', true);
export const PAD_GLASS: uiMaterial.Material | undefined = glass(uiMaterial.ImmersiveStyle.ULTRA_THIN, '#08FFFFFF', false);
export const PRESSED_GLASS: uiMaterial.Material | undefined = glass(uiMaterial.ImmersiveStyle.THIN, '#3A8DE0E7', false);
