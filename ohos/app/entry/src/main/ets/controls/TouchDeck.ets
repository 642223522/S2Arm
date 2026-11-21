import engine from 'libs2aprobehost.so';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { touchPulse } from './TouchFeedback';
import { Glass, IMMERSIVE } from '../ui/Theme';
import { str } from '../ui/Strings';
import { PadButton, PadStick, PadContact, TouchProfile, ButtonLook, ICONS, ICON_NAMES, PRESET_NAMES,
  defaultProfile, actionProfile, cloneProfile, parseProfile, buttonBit, buttonLabel, stickAxes } from './TouchModel';

@Component
export struct TouchDeck {
  gameId: string = '';
  gameTitle: string = '';
  filesDir: string = '';
  preview: boolean = false;
  editOnOpen: boolean = false;
  onClose: () => void = () => {};
  onEditing: (editing: boolean) => void = () => {};
  @StorageLink('s2armForeground') @Watch('foregroundChanged') foreground: boolean = true;
  @StorageLink('s2armFocused') @Watch('foregroundChanged') focused: boolean = true;
  @StorageLink('s2armTouchFeedback') touchFeedback: boolean = false;
  @State editing: boolean = false;
  @State inspector: boolean = false;
  @State selectedId: string = 'A';
  @State label: string = 'A';
  @State controlSize: number = 18;
  @State controlOpacity: number = 72;
  @State status: string = '';
  @State exchange: boolean = false;
  @State exchangeText: string = '';
  @State glassButtons: PadButton[] = [];
  @State glassLabels: string[] = [];
  @State glassActive: string[] = [];
  @State auxiliary: boolean = true;
  @State glassOpacity: number = 0.72;
  @State glassCaptions: string[] = [];
  @State idle: boolean = false;
  private idleTimer: number = -1;
  @State skin: string = 'console';
  @State presetName: string = str(PRESET_NAMES[0]);
  @State deadzone: number = 8;
  @State fileBusy: boolean = false;
  private profile: TouchProfile = defaultProfile();
  private saved: TouchProfile = defaultProfile();
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private contacts: Map<number, PadContact> = new Map<number, PadContact>();
  @State canvasWidth: number = 1;
  @State canvasHeight: number = 1;
  private initialized: boolean = false;

  aboutToAppear() {
    this.profile = defaultProfile();
    try {
      const path = this.profilePath();
      if (fs.accessSync(path) && fs.statSync(path).size <= 65536) this.profile = parseProfile(fs.readTextSync(path));
    } catch (error) { this.status = str($r('app.string.layout_read_failed')); }
    this.saved = cloneProfile(this.profile);
    this.controlOpacity = Math.round(this.profile.opacity * 100);
    this.editing = this.preview || this.editOnOpen;
    this.onEditing(this.editing);
    this.skin = this.profile.skin ?? 'console';
    this.presetName = this.profile.layout.name;
    this.deadzone = Math.round((this.profile.deadzone ?? 0.08) * 100);
    this.choose('A');
  }
  aboutToDisappear() { if (this.idleTimer >= 0) clearTimeout(this.idleTimer); this.release(); this.onEditing(false); }
  // 3 秒没碰就淡下去，按下立即恢复（参照上游 vpad 的 idle fade）。
  private wake() {
    if (this.idleTimer >= 0) clearTimeout(this.idleTimer);
    if (this.idle) this.getUIContext().animateTo({ duration: 120 }, () => this.idle = false);
    this.idleTimer = setTimeout(() => {
      this.idleTimer = -1;
      if (this.contacts.size === 0 && !this.editing) this.getUIContext().animateTo({ duration: 400, curve: Curve.EaseOut }, () => this.idle = true);
    }, 3000);
  }
  private profilePath(): string { return this.filesDir + '/control-layouts/' + this.gameId + '.json'; }
  private foregroundChanged() { this.release(); }
  private release() {
    this.contacts.clear();
    engine.input(0, 0, 0, 0, 0);
    if (this.initialized) this.draw();
  }
  private side(): number { return Math.max(1, Math.min(this.canvasWidth - 48, this.canvasHeight - 48)); }
  private px(x: number): number { return 24 + x * (this.canvasWidth - 48); }
  private py(y: number): number { return 24 + y * (this.canvasHeight - 48); }
  private buttonX(b: PadButton): number { const half = b.width * this.side() / 2; return Math.max(24 + half, Math.min(this.canvasWidth - 24 - half, this.px(b.x))); }
  private buttonY(b: PadButton): number { const half = b.height * this.side() / 2; return Math.max(48 + half, Math.min(this.canvasHeight - 24 - half, this.py(b.y))); }
  private look(id: string): ButtonLook {
    return this.profile.looks.find((x: ButtonLook) => x.id === id) ?? { id: id, label: buttonLabel(id), icon: '字母' };
  }
  private choose(id: string) {
    this.selectedId = id;
    const b = this.profile.layout.buttons.find((x: PadButton) => x.id === id);
    const s = this.profile.layout.sticks.find((x: PadStick) => 'stick-' + x.id === id);
    this.label = b ? this.look(id).label : str(id === 'stick-left' ? $r('app.string.left_stick') : $r('app.string.right_stick'));
    this.controlSize = Math.round((b ? b.width : s ? s.radius : 0.15) * 100);
  }
  private editLook(label: string, icon: string) {
    if (this.selectedId.startsWith('stick-')) return;
    const looks = this.profile.looks.filter((x: ButtonLook) => x.id !== this.selectedId);
    looks.push({ id: this.selectedId, label: label, icon: icon });
    this.profile.looks = looks;
    this.label = label; this.draw();
  }
  private resize(value: number) {
    this.controlSize = value;
    const b = this.profile.layout.buttons.find((x: PadButton) => x.id === this.selectedId);
    if (b) { b.width = value / 100; b.height = value / 100; b.cornerRadius = value / 200; }
    const s = this.profile.layout.sticks.find((x: PadStick) => 'stick-' + x.id === this.selectedId);
    if (s) s.radius = value / 100;
    this.draw();
  }
  private save() {
    try {
      parseProfile(JSON.stringify(this.profile));
      const directory = this.filesDir + '/control-layouts';
      if (!fs.accessSync(directory)) fs.mkdirSync(directory, true);
      const path = this.profilePath();
      const temp = path + '.tmp';
      const file = fs.openSync(temp, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try { fs.writeSync(file.fd, JSON.stringify(this.profile)); fs.fsyncSync(file.fd); } finally { fs.closeSync(file); }
      if (fs.accessSync(path)) {
        const history = directory + '/history';
        if (!fs.accessSync(history)) fs.mkdirSync(history);
        fs.copyFileSync(path, history + '/' + this.gameId + '-' + Date.now().toString() + '.json');
      }
      fs.renameSync(temp, path);
      this.saved = cloneProfile(this.profile); this.status = str($r('app.string.layout_saved'));
      this.editing = false; this.onEditing(false); this.inspector = false; this.release();
      if (this.preview) this.onClose();
    } catch (error) { this.status = str($r('app.string.layout_save_failed'), String(error)); }
  }
  private cancel() {
    this.profile = cloneProfile(this.saved); this.controlOpacity = Math.round(this.profile.opacity * 100);
    this.editing = false; this.onEditing(false); this.inspector = false; this.release();
    if (this.preview) this.onClose();
  }
  private shown(id: string): boolean {
    return this.editing || this.auxiliary || this.profile.layout.id.endsWith('-menu') || ['LS', 'RS'].indexOf(id) < 0;
  }
  private hit(x: number, y: number): string {
    for (let i = this.profile.layout.buttons.length - 1; i >= 0; i--) {
      const b = this.profile.layout.buttons[i];
      if (!this.shown(b.id)) continue;
      if (Math.abs(x - this.buttonX(b)) <= Math.max(44, b.width * this.side()) / 2 && Math.abs(y - this.buttonY(b)) <= Math.max(44, b.height * this.side()) / 2) return b.id;
    }
    for (const s of this.profile.layout.sticks) {
      const r = s.activation;
      if (x >= this.px(r.x) && x <= this.px(r.x + r.width) && y >= this.py(r.y) && y <= this.py(r.y + r.height)) return 'stick-' + s.id;
    }
    return '';
  }
  private touchLogs: number = 0;
  private touch(e: TouchEvent) {
    if (this.touchLogs < 12) {
      this.touchLogs++;
      console.info(`S2ArmTouch type=${e.type} fg=${this.foreground} focused=${this.focused} exchange=${this.exchange} ` +
        `n=${e.changedTouches.length} x=${e.changedTouches.length ? e.changedTouches[0].x : -1} ` +
        `y=${e.changedTouches.length ? e.changedTouches[0].y : -1} canvas=${this.canvasWidth}x${this.canvasHeight}`);
    }
    if (!this.foreground || !this.focused || this.exchange) return;
    if (!this.editing) this.wake();
    if (e.type === TouchType.Cancel) { this.release(); return; }
    for (const point of e.changedTouches) {
      if (e.type === TouchType.Down) {
        const control = this.hit(point.x, point.y);
        if (!control) continue;
        if (this.editing) { this.choose(control); this.status = str($r('app.string.layout_edit_hint')); }
        if (control.startsWith('stick-') && Array.from(this.contacts.values()).some((c: PadContact) => c.control === control)) continue;
        if (this.editing && this.contacts.size > 0) continue;
        this.contacts.set(point.id, { pointer: point.id, control: control, originX: point.x, originY: point.y, x: point.x, y: point.y });
        if (!this.editing && !control.startsWith('stick-')) touchPulse(this.touchFeedback);
      } else if (e.type === TouchType.Up) {
        this.contacts.delete(point.id);
      } else if (e.type === TouchType.Move) {
        const contact = this.contacts.get(point.id);
        if (!contact) continue;
        if (this.editing) {
          const dx = (point.x - contact.x) / (this.canvasWidth - 48);
          const dy = (point.y - contact.y) / (this.canvasHeight - 48);
          const b = this.profile.layout.buttons.find((v: PadButton) => v.id === contact.control);
          if (b) { b.x = Math.max(0.03, Math.min(0.97, b.x + dx)); b.y = Math.max(0.06, Math.min(0.94, b.y + dy)); }
          const s = this.profile.layout.sticks.find((v: PadStick) => 'stick-' + v.id === contact.control);
          if (s) { s.activation.x = Math.max(0, Math.min(1 - s.activation.width, s.activation.x + dx)); s.activation.y = Math.max(0, Math.min(1 - s.activation.height, s.activation.y + dy)); }
        }
        contact.x = point.x; contact.y = point.y;
      }
    }
    if (!this.editing) this.publish();
    this.draw();
  }
  private publish() {
    let bits = 0; let lx = 0; let ly = 0; let rx = 0; let ry = 0;
    for (const c of this.contacts.values()) {
      if (c.control.startsWith('stick-')) {
        const s = this.profile.layout.sticks.find((v: PadStick) => 'stick-' + v.id === c.control);
        if (!s) continue;
        const radius = s.radius * this.side();
        const dx = (c.x - c.originX) / radius; const dy = (c.originY - c.y) / radius;
        const axes = stickAxes(dx, dy, this.profile.deadzone ?? 0.08);
        const x = axes[0]; const y = axes[1];
        if (s.id === 'left') { lx = x; ly = y; } else { rx = x; ry = y; }
      } else bits |= buttonBit(c.control);
    }
    engine.input(bits, lx, ly, rx, ry);
  }
  private circle(x: number, y: number, r: number, fill: string, stroke: string) {
    this.context.beginPath(); this.context.arc(x, y, r, 0, Math.PI * 2);
    this.context.fillStyle = fill; this.context.fill(); this.context.strokeStyle = stroke; this.context.lineWidth = 1.4; this.context.stroke();
  }
  private symbol(icon: string, x: number, y: number, size: number) {
    const c = this.context; const s = size / 2;
    c.strokeStyle = '#F2F7FC'; c.lineWidth = 2.2; c.beginPath();
    if (icon === '攻击') { c.moveTo(x-s, y+s); c.lineTo(x+s, y-s); c.lineTo(x+s*.5, y-s); c.moveTo(x-s*.4,y+s*.1); c.lineTo(x-s*.1,y+s*.4); }
    if (icon === '跳跃') { c.moveTo(x-s,y+s*.3); c.lineTo(x,y-s*.5); c.lineTo(x+s,y+s*.3); c.moveTo(x,y-s*.5); c.lineTo(x,y+s); }
    if (icon === '冲刺') { for (let i=0;i<3;i++) { const a=x-s+i*s*.65; c.moveTo(a,y-s*.5); c.lineTo(a+s*.6,y); c.lineTo(a,y+s*.5); } }
    if (icon === '技能') { c.moveTo(x,y-s); c.lineTo(x+s*.25,y-s*.25); c.lineTo(x+s,y); c.lineTo(x+s*.25,y+s*.25); c.lineTo(x,y+s); c.lineTo(x-s*.25,y+s*.25); c.lineTo(x-s,y); c.lineTo(x-s*.25,y-s*.25); c.closePath(); }
    if (icon === '背包') { c.rect(x-s*.75,y-s*.5,s*1.5,s*1.4); c.moveTo(x-s*.4,y-s*.5); c.lineTo(x-s*.4,y-s*.9); c.lineTo(x+s*.4,y-s*.9); c.lineTo(x+s*.4,y-s*.5); }
    c.stroke();
  }
  private draw() {
    if (!this.initialized) return;
    const c = this.context; c.clearRect(0,0,this.canvasWidth,this.canvasHeight);
    if (this.preview || this.editing) {
      c.fillStyle = this.preview ? '#0C1422' : '#88181C19'; c.fillRect(0,0,this.canvasWidth,this.canvasHeight);
      c.strokeStyle = '#2E372F'; c.lineWidth = 1;
      for (let x=24;x<this.canvasWidth;x+=40) { c.beginPath();c.moveTo(x,48);c.lineTo(x,this.canvasHeight-24);c.stroke(); }
      for (let y=48;y<this.canvasHeight;y+=40) { c.beginPath();c.moveTo(24,y);c.lineTo(this.canvasWidth-24,y);c.stroke(); }
      if (this.preview) { c.fillStyle='#ABB9CB';c.font='14px sans-serif';c.textAlign='center';c.fillText(str($r('app.string.layout_drag_hint')),this.canvasWidth/2,this.canvasHeight*.38); }
    }
    c.globalAlpha = this.editing ? 1 : this.profile.opacity;
    for (const s of this.profile.layout.sticks) {
      const r=s.activation; const active=Array.from(this.contacts.values()).find((v: PadContact)=>v.control==='stick-'+s.id);
      const x=active&&!this.editing?active.originX:this.px(r.x+r.width/2); const y=active&&!this.editing?active.originY:this.py(r.y+r.height/2);
      const radius=s.radius*this.side();
      if(this.editing) { c.strokeStyle=this.selectedId==='stick-'+s.id?'#A6E3E8':'#607064';c.setLineDash([5,5]);c.strokeRect(this.px(r.x),this.py(r.y),r.width*(this.canvasWidth-48),r.height*(this.canvasHeight-48));c.setLineDash([]); }
      // 浮动摇杆：静止时只留一圈淡环提示位置；按下处出现底盘与摇杆头。
      const knobR=radius*.42;
      c.save(); c.globalAlpha=(this.editing?1:this.profile.opacity)*(active||this.editing?1:(this.idle?.35:.6));
      c.beginPath(); c.arc(x,y,radius,0,Math.PI*2);
      c.fillStyle=active?'#330B0B0F':'#1A0B0B0F'; c.fill();
      c.lineWidth=1.2; c.strokeStyle=active?'#66FFFFFF':'#40FFFFFF'; c.stroke();
      const dx=active&&!this.editing?active.x-x:0;const dy=active&&!this.editing?active.y-y:0;
      const limit=Math.max(1,Math.sqrt(dx*dx+dy*dy)/(radius-knobR*.5));
      c.shadowBlur=active?12:0; c.shadowColor='#66000000'; c.shadowOffsetY=2;
      c.beginPath(); c.arc(x+dx/limit,y+dy/limit,knobR,0,Math.PI*2);
      c.fillStyle=active?'#E6F5F7FA':'#4DF5F7FA'; c.fill();
      c.restore();
    }
    // ArkUI owns text. Stable pointer IDs keep the input merge/release contract.
    // Keep stable pointer IDs and the existing merge/release contract.
    this.glassButtons = this.profile.layout.buttons.filter((b: PadButton) => this.shown(b.id));
    this.glassLabels = this.glassButtons.map((b: PadButton) => buttonLabel(b.id));
    // 动作名只作小字副标题：编辑时总显示；游戏中只在面键、肩键上显示。
    this.glassCaptions = this.glassButtons.map((b: PadButton) => {
      const look = this.look(b.id);
      const main = ['A', 'B', 'X', 'Y', 'L', 'R', 'ZL', 'ZR'].indexOf(b.id) >= 0;
      return look.label !== buttonLabel(b.id) && (this.editing || main) ? look.label : '';
    });
    this.skin = this.profile.skin ?? 'console';
    this.presetName = this.profile.layout.name;
    this.glassActive = Array.from(this.contacts.values()).map((v: PadContact) => v.control);
    this.glassOpacity = this.editing ? 1 : this.profile.opacity;
    c.globalAlpha=1;
  }
  private usePreset(index: number) {
    this.release();
    this.profile = index === 0 ? defaultProfile() : actionProfile(index === 2 ? 'combat' : index === 3 ? 'menu' : 'explore');
    this.controlOpacity = Math.round(this.profile.opacity * 100);
    this.deadzone = Math.round((this.profile.deadzone ?? 0.08) * 100);
    this.choose('A');
    this.status = str($r('app.string.layout_preset_preview'));
    this.draw();
  }
  private applyImport(text: string) {
    const next = parseProfile(text.replace(/^\uFEFF/, ''));
    this.profile = next;
    this.controlOpacity = Math.round(next.opacity * 100);
    this.deadzone = Math.round((next.deadzone ?? 0.08) * 100);
    this.choose('A'); this.exchange = false;
    this.status = str($r('app.string.layout_loaded')); this.release();
  }
  private async importFile() {
    if (this.fileBusy) return;
    this.fileBusy = true; this.release();
    try {
      const view = new picker.DocumentViewPicker(getContext(this) as common.UIAbilityContext);
      const uris = await view.select({ maxSelectNumber: 1, fileSuffixFilters: [str($r('app.string.touch_layout')) + '|.json'] });
      if (uris.length === 0) return;
      const file = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
      let text = '';
      try {
        const info = fs.statSync(file.fd);
        if (!info.isFile() || info.size < 1 || info.size > 65536) throw new Error(str($r('app.string.layout_file_too_large')));
        const bytes = new Uint8Array(info.size);
        let done = 0;
        while (done < info.size) {
          const buffer = new ArrayBuffer(Math.min(4096, info.size - done));
          const count = fs.readSync(file.fd, buffer);
          if (count < 1) throw new Error(str($r('app.string.file_read_incomplete')));
          bytes.set(new Uint8Array(buffer, 0, count), done); done += count;
        }
        text = util.TextDecoder.create('utf-8', { fatal: true, ignoreBOM: true }).decodeToString(bytes);
      } finally { fs.closeSync(file); }
      this.applyImport(text);
    } catch (error) { this.status = str($r('app.string.layout_not_imported'), String(error)); }
    finally { this.fileBusy = false; }
  }
  private async exportFile() {
    if (this.fileBusy) return;
    this.fileBusy = true; this.release();
    try {
      parseProfile(JSON.stringify(this.profile));
      const view = new picker.DocumentViewPicker(getContext(this) as common.UIAbilityContext);
      const uris = await view.save({ newFileNames: ['S2Arm-' + this.profile.layout.id + '.json'], fileSuffixChoices: [str($r('app.string.touch_layout')) + '|.json'] });
      if (uris.length === 0) return;
      const file = fs.openSync(uris[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try { fs.writeSync(file.fd, JSON.stringify(this.profile, null, 2)); fs.fsyncSync(file.fd); }
      finally { fs.closeSync(file); }
      this.status = str($r('app.string.layout_exported'));
    } catch (error) { this.status = str($r('app.string.layout_not_exported'), String(error)); }
    finally { this.fileBusy = false; }
  }
  @Builder padBar() {
    Row({space:8}) {
      if(this.editing) Text($r('app.string.touch_layout')).fontColor('#F2F7FC').fontSize(14).fontWeight(FontWeight.Medium)
      if(this.editing) {
        Text(this.gameTitle).fontColor('#ABB9CB').fontSize(11).maxLines(1).width(150)
        Button($r('app.string.appearance')).fontSize(12).height(32).backgroundColor('#1C2C42').onClick(()=>this.inspector=!this.inspector)
        Select(PRESET_NAMES.map((name: Resource): SelectOption => ({ value: str(name) })))
          .value(this.presetName).font({ size: 11 }).fontColor('#D9E7E2').backgroundColor('#182622').height(32).width(150)
          .onSelect((index: number): void => { this.usePreset(index); })
        Button($r('app.string.import_export')).fontSize(12).height(32).backgroundColor('#1C2C42').onClick(()=>{this.release();this.exchangeText=JSON.stringify(this.profile,null,2);this.exchange=true;})
        Blank()
        Button($r('app.string.cancel')).fontSize(12).height(32).backgroundColor('#1C2C42').onClick(()=>this.cancel())
        Button($r('app.string.save_layout')).fontSize(12).height(32).backgroundColor('#A6E3E8').fontColor('#102334').onClick(()=>this.save())
      } else {
        Blank()
        Button(this.auxiliary ? $r('app.string.aux_hide') : $r('app.string.aux_show')).fontSize(10).height(44).fontColor('#F2F7FC').backgroundColor('#221C2C42').onClick(()=>{this.release();this.auxiliary=!this.auxiliary;this.draw();})
        Button($r('app.string.layout')).fontSize(10).height(44).fontColor('#F2F7FC').backgroundColor('#5010171D').onClick(()=>{this.release();this.saved=cloneProfile(this.profile);this.editing=true;this.onEditing(true);this.draw();})
        Button($r('app.string.hide')).fontSize(10).height(44).fontColor('#F2F7FC').backgroundColor('#221C2C42').onClick(()=>{this.release();this.onClose();})
      }
    }.padding({left:24,right:24,top:8,bottom:8}).width('100%').backgroundColor(this.editing?'#F0181C19':'#00181C19')
  }
  @Builder properties() {
    Column({space:10}) {
      Text(this.selectedId.startsWith('stick-')?this.label:str($r('app.string.button_named'), this.selectedId)).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#F2F7FC')
      if(!this.selectedId.startsWith('stick-')) {
        TextInput({text:this.label,placeholder:$r('app.string.button_name')}).height(40).maxLength(12).fontColor('#F2F7FC').backgroundColor('#0C1422')
          .onChange((v:string)=>this.editLook(v,this.look(this.selectedId).icon))
        Select(ICON_NAMES.map((x:Resource):SelectOption=>({value:x})))
          .value(ICON_NAMES[Math.max(0, ICONS.indexOf(this.look(this.selectedId).icon))]).fontColor('#F2F7FC')
          .onSelect((index:number)=>this.editLook(this.label,ICONS[index]))
      }
      Text($r('app.string.size_value', this.controlSize)).fontColor('#ABB9CB').fontSize(12)
      Slider({value:this.controlSize,min:6,max:30,step:1}).selectedColor('#A6E3E8').onChange((v:number)=>this.resize(v))
      Text($r('app.string.opacity_value', this.controlOpacity.toString()+'%')).fontColor('#ABB9CB').fontSize(12)
      Slider({value:this.controlOpacity,min:20,max:100,step:5}).selectedColor('#A6E3E8').onChange((v:number)=>{this.controlOpacity=v;this.profile.opacity=v/100;this.draw();})
      Text($r('app.string.deadzone_value', this.deadzone.toString()+'%')).fontColor('#ABB9CB').fontSize(12)
      Slider({value:this.deadzone,min:0,max:25,step:1}).selectedColor('#A6E3E8').onChange((v:number)=>{this.deadzone=v;this.profile.deadzone=v/100;})
      Text(this.status.length>0?this.status:$r('app.string.layout_inspector_hint')).fontColor('#ABB9CB').fontSize(11)
      Button($r('app.string.collapse')).height(30).fontSize(12).backgroundColor('#0C1422').onClick(()=>this.inspector=false)
    }.width(230).padding(16).backgroundColor('#16161C').borderRadius(18).position({x:24,y:58})
  }
  @Builder exchangeDialog() {
    Column({space:12}) {
      Text($r('app.string.share_layout')).fontColor('#F2F7FC').fontSize(20).fontWeight(FontWeight.Bold)
      Row({space:12}) {
        Button($r('app.string.import_from_file')).height(38).backgroundColor('#284237').enabled(!this.fileBusy).onClick(()=>this.importFile())
        Button($r('app.string.export_to_file')).height(38).backgroundColor('#284237').enabled(!this.fileBusy).onClick(()=>this.exportFile())
        Text($r('app.string.layout_formats')).fontSize(11).fontColor('#ABB9CB')
      }
      TextArea({text:this.exchangeText,placeholder:$r('app.string.paste_layout')}).height('38%').fontSize(11)
        .fontColor('#F2F7FC').backgroundColor('#0C1422').onChange((v:string)=>this.exchangeText=v)
      Row({space:12}) {
        Button($r('app.string.close')).backgroundColor('#0C1422').onClick(()=>this.exchange=false)
        Button($r('app.string.copy')).backgroundColor('#1C2C42').onClick(()=>{pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN,this.exchangeText)).then(()=>this.status=str($r('app.string.layout_copied')));})
        Button($r('app.string.apply_text')).backgroundColor('#A6E3E8').fontColor('#102334').onClick(()=>{try{this.applyImport(this.exchangeText);}catch(error){this.status=str($r('app.string.import_failed'), String(error));}})
      }
      Text(this.status).fontSize(12).fontColor('#ABB9CB')
    }.padding(24).width('78%').height('88%').backgroundColor('#16161C').borderRadius(20)
  }
  @Builder padKey(b: PadButton, glyph: string, caption: string, pressed: boolean) {
    // 玻璃圆钮：细描边 + 白字 + 投影，按下提亮并轻微下沉；不叠彩色底。
    Column({ space: 0 }) {
      Text(glyph).fontSize(this.glyphSize(b)).fontWeight(b.id.length === 1 ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(pressed ? '#FFFFFF' : '#F2F5F8').textAlign(TextAlign.Center).maxLines(1)
        .textShadow({ radius: 3, color: '#73000000', offsetY: 1 })
      if (caption.length > 0 && b.height * this.side() >= 44) {
        Text(caption).fontSize(Math.max(9, Math.min(11, b.height * this.side() * 0.17))).fontColor('#B3F2F5F8')
          .maxLines(1).textShadow({ radius: 3, color: '#73000000', offsetY: 1 })
      }
    }.justifyContent(FlexAlign.Center)
      .width(b.width * this.side()).height(b.height * this.side())
      .position({ x: this.buttonX(b) - b.width * this.side() / 2, y: this.buttonY(b) - b.height * this.side() / 2 })
      .backgroundColor(IMMERSIVE ? (pressed ? '#2EFFFFFF' : Color.Transparent) : (pressed ? '#59FFFFFF' : '#2E0B0B0F'))
      .systemMaterial(pressed ? Glass.padPressed : Glass.pad)
      .borderRadius(b.cornerRadius * this.side())
      .border({ width: this.editing && this.selectedId === b.id ? 2 : 1,
        color: this.editing && this.selectedId === b.id ? '#E6FFFFFF' : pressed ? '#99FFFFFF' : (this.skin === 'action' ? '#4DF0D691' : '#4DFFFFFF') })
      .shadow(pressed ? { radius: 6, color: '#40000000', offsetY: 1 } : { radius: 10, color: '#33000000', offsetY: 2 })
      .scale({ x: !this.editing && pressed ? 0.92 : 1, y: !this.editing && pressed ? 0.92 : 1 })
      .opacity(this.glassOpacity * (this.idle && !pressed ? 0.45 : 1)).hitTestBehavior(HitTestMode.None)
  }
  private glyphSize(b: PadButton): number {
    const h = b.height * this.side();
    const base = b.id.length === 1 ? 0.42 : ['UP', 'DOWN', 'LEFT', 'RIGHT'].indexOf(b.id) >= 0 ? 0.32 : 0.36;
    return Math.max(11, Math.min(26, h * base));
  }
  build() {
    Stack({alignContent:Alignment.TopStart}) {
      Canvas(this.context).width('100%').height('100%')
        .onReady(()=>{this.initialized=true;this.draw();})
        .onAreaChange((_old:Area,current:Area)=>{this.canvasWidth=Number(current.width);this.canvasHeight=Number(current.height);this.release();})
        .onTouch((e:TouchEvent)=>this.touch(e))
      ForEach(this.glassButtons, (b: PadButton, index: number) => {
        this.padKey(b, this.glassLabels[index] ?? b.id, this.glassCaptions[index] ?? '', this.glassActive.indexOf(b.id) >= 0)
      }, (b: PadButton, index: number) => b.id + (this.glassActive.indexOf(b.id) >= 0 ? '*' : '') + (this.glassCaptions[index] ?? ''))
      if (this.editing) this.padBar()
      if(this.editing&&this.inspector) this.properties()
      if(this.exchange) {
        Stack(){this.exchangeDialog()}.width('100%').height('100%').backgroundColor('#E6181C19')
      }
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.Transparent)
  }
}
