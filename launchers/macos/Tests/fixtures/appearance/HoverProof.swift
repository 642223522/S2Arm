// 手动界面复现夹具：与生产 Appearance.swift 一起编译；修改前版本另加 -D BEFORE。
import AppKit
import SwiftUI
func L(_ value:String)->String { value }
struct ReadabilityCard: View {
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("正在准备游戏").font(.headline)
            Text("初始化内置 S2Arm 引擎").font(.callout)
            Text("着色器翻译与编译进行中，请等待任务完成。").font(.callout).foregroundStyle(.secondary)
            ProgressView(value:0.5).tint(Brand.accent)
            HStack {Text("50%　50 / 100 个文件");Spacer();Text("已用 12 秒")}.font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
    }
}
@main struct HoverProof: App {
    var body:some Scene {
        WindowGroup("S2Arm 卡片悬停验证") {
            VStack(alignment:.leading,spacing:24) {
                Text("S2Arm · 鼠标高亮复现").font(.title2.bold())
                Text("直接加载生产 Appearance.swift；仅展示界面，不执行游戏任务。").font(.callout).foregroundStyle(.secondary)
                #if BEFORE
                ReadabilityCard().contentCard(20).lightFollow(20)
                #else
                ReadabilityCard().contentCard(20)
                #endif
                #if BEFORE
                ReadabilityCard().pressCard(24).lightFollow(24)
                #else
                ReadabilityCard().glassSurface(20)
                #endif
                Text("上：游戏库内容卡　下：任务页系统材质卡。将鼠标放到正文，检查文字可读性。").font(.caption).foregroundStyle(.secondary)
            }.padding(30).frame(width:900,height:640).background(LibraryBackdrop()).environment(\.colorScheme,.light)
        }.defaultSize(width:900,height:640)
    }
}
