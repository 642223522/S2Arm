import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SaveUsers: Decodable { var ids: [String]; var active: String }
struct SaveOwnershipView: View {
    let users: SaveUsers

    var body: some View {
        if users.ids.isEmpty {
            Label(L("仅含设备存档，不属于单个用户。"),systemImage:"externaldrive")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            DisclosureGroup(L("存档所属用户")) {
                VStack(alignment:.leading,spacing:6) {
                    ForEach(users.ids,id:\.self) { id in
                        Text(id).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
        }
    }
}
struct SaveStatus: Decodable {
    var hasSave: Bool; var fileCount: Int; var totalBytes: Int64
    var users: SaveUsers?; var previousBackup: String; var recovered: Bool
    // 自动回退失败时后端给的事务记录路径（pack/jobs/saves.py status；旧后端没有这个字段）：检查 / 备份照常可做
    var recoveryFailed: String?
}
struct SaveManifestSummary: Decodable {
    struct GameIdentity: Decodable { var id: String; var name: String; var version: Int64 }
    var schema: Int; var createdAt: String; var game: GameIdentity; var users: SaveUsers
}
struct SavePreview: Decodable {
    var manifest: SaveManifestSummary; var archiveSha256: String; var targetFingerprint: String
    var previewLibraryId: String; var fileCount: Int; var totalBytes: Int64
    // 社区存档目录结构存疑时后端给的一句提示（pack/jobs/saves.py STRUCTURE_NOTICE），旧后端没有这个字段
    var notice: String?
    var request: [String:Any] {
        ["archiveSha256":archiveSha256,"targetFingerprint":targetFingerprint,"previewLibraryId":previewLibraryId]
    }
}

extension Store {
    var canManageSaves: Bool { !preferences.library.isEmpty && !executionBusy && queue.isEmpty }

    @discardableResult func saveJob(_ operation: String, game: Game, path: URL? = nil,
                                   preview: SavePreview? = nil, completion: @escaping ([String:Any])->Void) -> String? {
        guard canManageSaves else { return nil }
        var request: [String:Any] = ["gameId":game.id]
        if let path { request["path"] = path.path }
        if let preview { preview.request.forEach { request[$0] = $1 } }
        executionTask = worker(operation,extra:request,visible:operation != "saveStatus",completion:completion)
        return executionTask
    }
}

struct SaveManagementView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let game: Game
    @State private var status: SaveStatus?
    @State private var preview: SavePreview?
    @State private var source: URL?
    @State private var confirmRestore = false
    @State private var needsRefresh = false
    @State private var message: String?
    // 结果带清理警告（事务目录没清完、下次启动会再走回退）：用警告样式，不打勾（审计 18:00 P2-32）
    @State private var messageWarns = false
    static func resultIcon(warns: Bool) -> String { warns ? "exclamationmark.triangle.fill" : "checkmark.circle" }
    private var activeTask: TaskRecord? {
        store.tasks.first { $0.gameId == game.id && $0.active && ["saveBackup","saveInspect","saveRestore"].contains($0.operation) }
    }
    private let backupType = UTType(exportedAs:"org.s2arm.save-backup",conformingTo:.zip)

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Label(L("存档备份与恢复"),systemImage:"externaldrive.badge.timemachine").font(.headline)
                Spacer()
                Button(L("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(game.name).font(.headline)
            Text(L("请先停止游戏。恢复前会校验备份并保留当前存档的原副本。")).font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    currentSave
                    backupPanel
                    restorePanel
                    if let message { Label(L(message),systemImage:Self.resultIcon(warns:messageWarns)).foregroundStyle(messageWarns ? .orange : .teal).font(.callout) }
                    if let task = activeTask { TaskCard(task:task) }
                    if !store.canManageSaves, activeTask == nil {
                        Text(L("请等待当前任务结束，或先结束正在运行的游戏。")).font(.callout).foregroundStyle(.orange)
                        if let task=store.tasks.first(where:{$0.operation=="launch" && $0.active}) {
                            Button(L("结束游戏")) { store.cancel(task) }.disabled(task.state=="cancelling")
                        }
                    }
                }.padding(2)
            }
        }.padding(WorkspaceLayout.pageInset).frame(width:640,height:580).controlSize(.small).background(LibraryBackdrop())
            .task { refresh() }
            .onChange(of:store.executionBusy) { _, busy in
                if !busy && needsRefresh { needsRefresh=false;refresh() }
            }
            .alert(L("操作未完成"),isPresented:Binding(get:{store.error != nil},set:{if !$0 {store.error=nil}})) {
                Button(L("知道了"),role:.cancel) { store.error=nil }
                if let diagnostic=store.errorDiagnostic {
                    Button(L("复制错误摘要")) { store.copyDiagnostic(diagnostic) }
                }
            } message: { Text(store.failureMessage) }
            .alert(L("恢复该备份？"),isPresented:$confirmRestore) {
                Button(L("取消"),role:.cancel) {}
                Button(L("恢复并保留原副本"),role:.destructive) { restore() }
            } message: {
                Text(L("当前游戏存档将替换为已检查的备份。恢复前的存档会自动保留；游戏、用户或版本不符时不会恢复。"))
            }
    }

    private var currentSave: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack { Text(L("当前存档")).font(.headline);Spacer();Button(L("重新检查")) { refresh() }.disabled(!store.canManageSaves) }
            if let status {
                if status.hasSave {
                    LabeledContent(L("文件数量"),value:String(status.fileCount))
                    LabeledContent(L("存档大小"),value:bytes(status.totalBytes))
                    if let users=status.users { SaveOwnershipView(users:users) }
                } else {
                    Text(L("此游戏尚无可备份的存档，请先在游戏中保存。")).font(.callout).foregroundStyle(.secondary)
                }
                if status.recovered { Label(L("已将未完成的恢复回退到原存档。"),systemImage:"arrow.uturn.backward").font(.callout).foregroundStyle(.orange) }
                if let failed=status.recoveryFailed, !failed.isEmpty {
                    Label(L("上次的存档导入或恢复没做完，自动回退失败。可以先备份当前存档；启动游戏时会再确认是否仍要启动。记录不会删除，下次启动会再试恢复。"),systemImage:"exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    Button(L("在访达中显示事务记录")) { store.reveal(URL(fileURLWithPath:failed)) }
                }
                if !status.previousBackup.isEmpty {
                    Button(L("查看恢复前备份")) { store.reveal(URL(fileURLWithPath:status.previousBackup)) }
                }
            } else {
                Text(L("检查游戏存档与可恢复的原副本。")).font(.callout).foregroundStyle(.secondary)
            }
        }.frame(maxWidth:.infinity,alignment:.leading).padding(WorkspaceLayout.cardInset).contentCard(WorkspaceLayout.cardRadius)
    }

    private var backupPanel: some View {
        VStack(alignment:.leading,spacing:10) {
            Text(L("备份存档")).font(.headline)
            Text(L("生成独立的存档备份文件，包含用户和文件校验信息。原存档保持不变。")).font(.callout).foregroundStyle(.secondary)
            Button(L("备份存档…")) { backup() }.disabled(!store.canManageSaves || status?.hasSave != true)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(WorkspaceLayout.cardInset).contentCard(WorkspaceLayout.cardRadius)
    }

    private var restorePanel: some View {
        VStack(alignment:.leading,spacing:10) {
            Text(L("恢复存档")).font(.headline)
            // 审计 18:00 P2-44：原先「从别的模拟器 / 工具导入」另有一颗同名按钮、调同一次选择，玩家会以为两颗各收一种备份；合成这一颗，说明写在这里
            Text(L("可选 S2Arm 备份文件，也认得 JKSV、Checkpoint、yuzu、Ryujinx 的存档文件夹或 zip。选好后先显示预览，确认后才恢复；恢复会覆盖当前存档，覆盖前自动备份一份。")).font(.callout).foregroundStyle(.secondary)
            Button(L("选择并检查备份…")) { chooseBackup() }.disabled(!store.canManageSaves)
            if let source { Text(source.lastPathComponent).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if let preview {
                LabeledContent(L("备份游戏"),value:preview.manifest.game.name)
                LabeledContent(L("游戏版本编号"),value:String(preview.manifest.game.version))
                LabeledContent(L("备份时间"),value:preview.manifest.createdAt)
                LabeledContent(L("文件数量"),value:String(preview.fileCount))
                LabeledContent(L("存档大小"),value:bytes(preview.totalBytes))
                SaveOwnershipView(users:preview.manifest.users)
                if let notice=preview.notice, !notice.isEmpty {
                    // 社区存档结构存疑：照常可以恢复，只是先让玩家知道游戏可能读不到
                    Label(L(notice),systemImage:"questionmark.diamond").font(.callout).foregroundStyle(.orange)
                }
                Label(L("完整性、游戏版本和用户校验通过。"),systemImage:"checkmark.shield").font(.callout).foregroundStyle(.teal)
                Button(L("恢复此备份…")) { confirmRestore=true }.buttonStyle(.borderedProminent).disabled(!store.canManageSaves)
            } else {
                Text(L("先检查备份，再确认恢复。错误游戏、用户、版本或损坏的备份会被拒绝。")).font(.callout).foregroundStyle(.secondary)
            }
        }.frame(maxWidth:.infinity,alignment:.leading).padding(WorkspaceLayout.cardInset).contentCard(WorkspaceLayout.cardRadius)
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount:value,countStyle:.file)
    }
    private func refresh() {
        store.saveJob("saveStatus",game:game) { result in
            if let value=Store.decode(SaveStatus.self,result) { status=value }
            else { store.error="存档组件返回的信息不完整，请重新检查。" }
        }
    }
    private func backup() {
        let panel=NSSavePanel()
        panel.title=L("备份存档");panel.allowedContentTypes=[backupType];panel.canCreateDirectories=true
        let stamp=DateFormatter();stamp.dateFormat="yyyyMMdd-HHmmss"
        panel.nameFieldStringValue="\(game.id)-\(stamp.string(from:Date())).s2asave"
        guard panel.runModal() == .OK, let url=panel.url else { return }
        message=nil
        if store.saveJob("saveBackup",game:game,path:url,completion:{ _ in message="存档备份已完成。";messageWarns=false }) != nil { needsRefresh=true }
    }
    private func chooseBackup() {
        let panel=NSOpenPanel()
        panel.title=L("选择存档备份");panel.allowedContentTypes=[backupType,.zip,.folder]
        // 审计 18:00 P2-33：允许类型显式列上 .folder；只列备份类型和 zip 时文件夹能否选中取决于系统面板实现（待真面板实测），不赌它
        // 也收社区存档（JKSV / Checkpoint / yuzu / Ryujinx 的文件夹或 zip）：后端按布局转成本游戏的备份再走同一恢复流程（pack/jobs/save_formats.py）
        panel.canChooseDirectories=true;panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK, let url=panel.url else { return }
        preview=nil;source=url;message=nil
        store.saveJob("saveInspect",game:game,path:url) { result in
            if let value=Store.decode(SavePreview.self,result) { preview=value }
            else { store.error="存档组件返回的信息不完整，请重新检查。" }
        }
    }
    private func restore() {
        guard let preview, let source else { return }
        message=nil
        if store.saveJob("saveRestore",game:game,path:source,preview:preview,completion:{ result in
            // 事务记录没删掉时用后端原句（审计 P2-10），不写「已完成」
            let cleanup=result["cleanupWarning"] as? String ?? ""
            self.preview=nil;messageWarns = !cleanup.isEmpty;message = !cleanup.isEmpty ? cleanup : result["hadOriginal"] as? Bool == true ? "存档恢复已完成，恢复前副本已保留。" : "存档恢复已完成。"
        }) != nil { needsRefresh=true }
    }
}
