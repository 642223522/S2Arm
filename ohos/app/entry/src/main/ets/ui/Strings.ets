// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Player-visible text lives in resources/base/element/string.json. UI code uses $r('app.string.<name>')
// directly; str() is for text that logic stores or builds, filling %s / %d placeholders.
import { resourceManager } from '@kit.LocalizationKit';

let manager: resourceManager.ResourceManager | undefined = undefined;

export function bindStrings(value: resourceManager.ResourceManager): void { manager = value; }

export function str(res: Resource, ...args: Array<string | number>): string {
  if (manager === undefined) {
    console.error('S2Arm string resources used before bindStrings');
    return '';
  }
  try {
    return manager.getStringSync(res.id, ...args);
  } catch (error) {
    console.error('S2Arm string resource ' + res.id.toString() + ' unavailable: ' + String(error));
    return '';
  }
}
