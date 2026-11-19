// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import probe from 'libprobe.so';

@Entry
@Component
struct Index {
  @State out: string = '';

  aboutToAppear(): void {
    const dir = AppStorage.get<string>('filesDir') ?? '';
    this.out = probe.run(dir + '/smoke.txt');
  }

  build() {
    Column() {
      Text(this.out).fontSize(14).fontColor('#ffffff')
    }.width('100%').height('100%').backgroundColor('#000000')
  }
}
