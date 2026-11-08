import SwiftUI

// 把 iPhone 包装到手机（10-26 维护者定：出完包的提示常驻、带「查看装机步骤」，启动器里另有固定入口）：
//   启动器出的 IPA 是自签的，iPhone 不认（测试设备1 实测 ApplicationVerificationFailed），要用玩家自己的 Apple ID 重签。步骤与 docs/内测教程.md 第八、九节一致
//   10-26 维护者 定：主路 = Xcode 里登录的 Apple ID + 数据线，启动器「装到 iPhone」一键签名安装并拷资源包（pack/jobs/install.py）；AltStore 作备选，下面原来的五步就是它
//   11-02 用户体验线：主路从一页静态说明改成会自己打勾的清单（pack/jobs/install.py readiness，每 4 秒查一次）；玩家点了「装到 iPhone」的，清单齐了自动开装
struct InstallCheckItem: Identifiable, Equatable {
    let id: String, title: String, detail: String, who: String
    let ok: Bool, waiting: Bool
}
struct InstallReadiness: Equatable {
    var gameId: String
    var items: [InstallCheckItem]
    var ready: Bool
    var device: String
    var account: String
    init(gameId: String, items: [InstallCheckItem], ready: Bool, device: String = "", account: String = "") {
        self.gameId = gameId; self.items = items; self.ready = ready; self.device = device; self.account = account
    }
    init(_ r: [String:Any]) {
        gameId = r["gameId"] as? String ?? ""
        items = ((r["items"] as? [[String:Any]]) ?? []).map {
            InstallCheckItem(id:$0["id"] as? String ?? "", title:$0["title"] as? String ?? "", detail:$0["detail"] as? String ?? "",
                             who:$0["who"] as? String ?? "human", ok:$0["ok"] as? Bool ?? false, waiting:$0["waiting"] as? Bool ?? false)
        }
        ready = r["ready"] as? Bool ?? false
        device = r["device"] as? String ?? ""
        account = r["account"] as? String ?? ""
    }
    var json: [String:Any] {
        ["gameId":gameId, "ready":ready, "device":device, "account":account,
         "items":items.map { ["id":$0.id, "ok":$0.ok, "waiting":$0.waiting, "title":$0.title, "detail":$0.detail, "who":$0.who] as [String:Any] }]
    }
}

extension Store {
    /// 装机前清单要查哪款：点「装到 iPhone」时那款；从设置进来的，取选中的、再不行取最近出过 iPhone 包的
    var installGuideTarget: Game? {
        let id = installGuideGame ?? selectedGame ?? packShelf.first(where: { $0.latest != nil })?.gameId
        return games.first { $0.id == id }
    }
    /// 「装到 iPhone」：先开清单页；清单齐了自动开装，不齐就停在页上告诉玩家还差什么（已经齐的玩家照旧一次点击装上）
    func requestInstall(_ game: Game) {
        installGuideGame = game.id; installWhenReady = true; installReadiness = nil; showInstallGuide = true
        checkInstallReadiness()
    }
    /// 只读查一次（后台、不进任务列表；清单页和 AI 的 POST /installCheck 共用）。同一时刻只跑一个；卡住超过 45 秒的不算在跑（devicectl 偶尔很慢）
    func checkInstallReadiness(gameId: String? = nil) {
        guard let id = gameId ?? installGuideTarget?.id else { return }
        if let t = installCheckStarted, Date().timeIntervalSince(t) < 45 { return }
        installCheckStarted = Date()
        worker("installCheck", extra:["gameId":id], visible:false) { r in
            self.installCheckStarted = nil
            let rd = InstallReadiness(r)
            self.installReadiness = rd   // 页面只显示与当前那款同号的结果
            if rd.ready, rd.gameId == self.installGuideTarget?.id, self.installWhenReady, self.showInstallGuide, !self.executionBusy, let g = self.installGuideTarget {
                self.installWhenReady = false; self.showInstallGuide = false; self.installToPhone(g)
            }
        }
    }
    func installGuideDismissed() { installWhenReady = false; installGuideGame = nil }
}

struct InstallGuideView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    /// Xcode 数据线主路是否已经真机验证过（真机出画面）：装机步骤页、完成页、出完包的提示都读这一个开关，不各说各的（审计 P2-7）。验证过改成 true
    static let xcodeInstallVerified = false
    /// 清单还没查回来时显示的项（与 pack/jobs/install.py readiness 同序同句）
    static let pendingItems = ["这款游戏的 iPhone 版已经做好", "Xcode 里已登录 Apple ID", "iPhone 已用数据线连上", "iPhone 已信任这台 Mac", "iPhone 已打开开发者模式"]
    static let steps = [
        "在 Mac 上装 AltServer，再用它把 AltStore 装到 iPhone（按 altstore.io 官网说明）。推荐 AltStore Classic 2.2 或更新；不要用 SideStore 0.7.0，它会丢掉「提高内存上限」权限，大型游戏会打不开。",
        "iPhone 上打开「设置 → 隐私与安全性 → 开发者模式」，打开后按提示重启。",
        "把出好的 .ipa 用隔空投送或「文件」App 传到 iPhone，在 AltStore「我的 App」里点左上角「+」选它，按提示登录 Apple ID 完成安装。免费账号就可以。",
        "用数据线连上 iPhone，打开访达，左边选你的 iPhone →「文件」→ 找到这款游戏的 App，把同一文件夹里的整个「资源包」文件夹拖到它上面。",
        "打开游戏：第一次会先导入游戏资源，保持前台、不要锁屏，几分钟；导入完会自动进入游戏。",
    ]
    private var readiness: InstallReadiness? { store.installReadiness.flatMap { $0.gameId == store.installGuideTarget?.id ? $0 : nil } }
    var body: some View {
        VStack(alignment:.leading,spacing:WorkspaceLayout.sectionSpacing) {
            WorkspaceHeading(title:"装到 iPhone",subtitle:store.installGuideTarget?.name ?? "",symbol:"iphone.and.arrow.forward") {EmptyView()}
            ScrollView {
            VStack(alignment:.leading,spacing:WorkspaceLayout.sectionSpacing) {
            HStack(spacing:8) {
                Text(L("下面几项齐了就能装，这里每隔几秒自动检查一次。")).foregroundStyle(.secondary)
                if !Self.xcodeInstallVerified { VerifyingBadge().help(L("这条路还在真机验证，装不上或打不开时请改用下面的 AltStore。")) }
            }
            VStack(alignment:.leading,spacing:0) {
                if let rd = readiness {
                    ForEach(rd.items) { item in InstallCheckRow(item:item, suffix:suffix(item, rd)) }
                } else {
                    ForEach(Self.pendingItems, id:\.self) { title in InstallCheckRow(item:.init(id:title,title:title,detail:"",who:"",ok:false,waiting:true), suffix:"", checking:true) }
                }
            }
            Text(L("免费 Apple ID 签的 App 7 天过期，到时连上 iPhone 再装一次；已经在手机上的游戏资源不用重拷。同时最多 3 个自签 App。")).font(.callout).foregroundStyle(.secondary)
            Divider()
            CompactDisclosure(title:"其他安装方式：AltStore",symbol:"square.and.arrow.down.on.square") {
            Text(L("不想在 Xcode 里登录 Apple ID，或想让 App 在 Wi-Fi 下自动续签，就用 AltStore：")).font(.callout).foregroundStyle(.secondary)
            ForEach(Array(Self.steps.enumerated()), id:\.offset) { i, step in
                HStack(alignment:.top,spacing:10) {
                    Text("\(i + 1)").font(.headline).frame(width:24,height:24).background(Circle().fill(Brand.accent.opacity(0.18)))
                    Text(L(step)).fixedSize(horizontal:false,vertical:true)
                }
            }
            Text(L("免费 Apple ID 签的 App 7 天过期：Mac 上开着 AltServer、和 iPhone 在同一个 Wi-Fi 下会自动续签；过期了在 AltStore 点「刷新全部」，不用重新拷资源包。")).font(.callout).foregroundStyle(.secondary)
            if let ipa = store.lastIPAPath { Button(L("在访达中显示 iPhone 包")) { store.reveal(ipa) } }
            }
            }
            }
            HStack {
                if store.installWhenReady, readiness?.ready != true { Label(L("齐了会自动开始装"),systemImage:"clock").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button(L("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                // 清单缺「iPhone 版」时直接给出路：先去做（做好后再点「装到 iPhone」，清单会自己打勾）
                if readiness?.items.first(where: { $0.id == "package" })?.ok == false, let g = store.installGuideTarget {
                    Button { dismiss(); store.packIPhone(g) } label: { Label(L("先做 iPhone 版"),systemImage:"hammer") }.disabled(store.executionBusy)
                }
                // 不能点时也看得清（白底上灰掉的主按钮几乎看不见，同引导页 10-23 的做法）
                if readiness?.ready == true, !store.executionBusy {
                    Button { if let g = store.installGuideTarget { dismiss(); store.installToPhone(g) } } label: { Label(L("开始装"),systemImage:"iphone.and.arrow.forward") }
                        .platformButtonStyle(prominent:true).keyboardShortcut(.defaultAction)
                } else {
                    Label(L("开始装"),systemImage:"iphone.and.arrow.forward").font(.body.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal,14).padding(.vertical,5).background(Color.secondary.opacity(0.14),in:Capsule())
                }
            }
        }.padding(WorkspaceLayout.pageInset).frame(width:600,height:540).controlSize(.small).background(LibraryBackdrop())
        .task {   // 页开着就每 4 秒查一次（玩家去手机上点信任 / 开开发者模式，回来就看到打勾）
            while !Task.isCancelled {
                store.checkInstallReadiness()
                try? await Task.sleep(nanoseconds:4_000_000_000)
            }
        }
    }
    private func suffix(_ item: InstallCheckItem, _ rd: InstallReadiness) -> String {
        guard item.ok else { return "" }
        if item.id == "appleId", !rd.account.isEmpty { return "（\(rd.account)）" }
        if item.id == "connected", !rd.device.isEmpty { return "（\(rd.device)）" }
        return ""
    }
}

/// 清单一行：好了打勾；要玩家做的标橙色并写怎么做；等前一步的灰着
struct InstallCheckRow: View {
    let item: InstallCheckItem
    let suffix: String
    var checking = false
    var body: some View {
        HStack(alignment:.top,spacing:10) {
            Group {
                if checking { ProgressView().controlSize(.small) }
                else if item.ok { Image(systemName:"checkmark.circle.fill").foregroundStyle(Brand.accent) }
                else if item.waiting { Image(systemName:"circle").foregroundStyle(.tertiary) }
                else { Image(systemName:"exclamationmark.circle.fill").foregroundStyle(.orange) }
            }.font(.title3).frame(width:22)
            VStack(alignment:.leading,spacing:3) {
                Text(L(item.title) + suffix).fontWeight(item.ok || item.waiting ? .regular : .semibold)
                    .foregroundStyle(item.waiting && !checking ? .secondary : .primary)
                if !item.ok, !item.waiting, !item.detail.isEmpty {
                    Text(L(item.detail)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
            }
            Spacer(minLength:0)
        }.padding(.vertical,8)
        .accessibilityElement(children:.combine)
    }
}

/// 「验证中」小标：装机步骤页与完成页共用
struct VerifyingBadge: View {
    var body: some View {
        Text(L("验证中")).font(.caption.weight(.semibold)).padding(.horizontal,8).padding(.vertical,2)
            .background(Capsule().fill(Color.orange.opacity(0.18))).foregroundStyle(.orange)
    }
}
