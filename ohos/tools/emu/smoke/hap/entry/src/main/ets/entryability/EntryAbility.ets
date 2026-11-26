// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
export default class EntryAbility extends UIAbility {
  onCreate(): void { AppStorage.setOrCreate('filesDir', this.context.filesDir); }
  onWindowStageCreate(ws: window.WindowStage): void { ws.loadContent('pages/Index'); }
}
