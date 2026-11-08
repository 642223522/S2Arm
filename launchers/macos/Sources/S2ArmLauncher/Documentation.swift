// Adapted from LumaDock (MIT); see ../../README.md.
import SwiftUI

enum AppGuide: String {
    case environment, licenses
    var title: String { self == .environment ? L("环境与数据说明") : L("开源许可与版权说明") }
    var text: String {
        self == .environment ? L("S2Arm 引擎、Python 及其依赖、.NET 运行时、编译工具和共享字体都随应用内置。编译游戏需要完整 Xcode 与 Metal 编译组件（缺了在检测项旁一键处理），启动已编译的游戏不需要 Xcode。玩家只需放入 prod.keys 和游戏（本体、更新、DLC）。") : L("界面与部分任务管理代码移植自 LumaDock，采用 MIT License，保留原版权声明。S2Arm 使用 Ryujinx、LibHac、SPIRV-Cross 等组件，各自许可证保持有效。详见应用内 README.md 中的版权声明及各组件的第三方许可文件。项目不附带游戏、密钥、固件或存档，与 Nintendo 无隶属关系。")
    }
}
struct DocumentationView: View {
    let guide:AppGuide
    var body:some View {ScrollView{VStack(alignment:.leading,spacing:20){Text(guide.title).font(.largeTitle.bold());Text(guide.text).textSelection(.enabled)}.padding(30).frame(maxWidth:.infinity,alignment:.leading)}}
}
