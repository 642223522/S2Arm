import { vibrator } from '@kit.SensorServiceKit';

// Touch feedback never synthesizes game rumble. Both switches remain independent.
let checked: boolean = false;
let supported: boolean = false;
let lastPulse: number = 0;

export function touchFeedbackSupported(): boolean {
  if (!checked) {
    checked = true;
    try { supported = vibrator.isSupportEffectSync(vibrator.HapticFeedback.EFFECT_SOFT); }
    catch (error) { supported = false; }
  }
  return supported;
}

export function touchPulse(enabled: boolean): void {
  if (!enabled || !AppStorage.get<boolean>('s2armForeground') || !touchFeedbackSupported()) return;
  const now = Date.now();
  if (now - lastPulse < 45) return;
  lastPulse = now;
  vibrator.startVibration({ type: 'preset', effectId: vibrator.HapticFeedback.EFFECT_SOFT, count: 1, intensity: 45 },
    { usage: 'touch' }).catch(() => { supported = false; });
}

export function stopTouchFeedback(): void {
  if (checked && supported) vibrator.stopVibration().catch(() => {});
}
