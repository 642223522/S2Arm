// S2Arm（不是上游文件）：出包页「签名方式」一栏 + 导入开发者证书弹窗（v0.2.4，作业层 pack/jobs/devcert.py）。
//   一栏：Apple ID 签名 / 我的开发者证书 二选一；选了证书，下面列团队、到期、包名、设备列表核对，问题黄字（不挡）、根本签不了红字。
//   弹窗：拖进或选 .p12 与 .mobileprovision，输密码，点导入；失败原因留在弹窗里，成了自动关。
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NXCore
import NXModel
import NXLauncher
import S2ArmAppleAdapter

private func sx(_ loc: Localizer, _ id: String) -> String { BackendText.launcherText("export.sign." + id, language: loc.lang.sharedCode) }

struct DevCertRow: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    /// 标题与「不用证书」那一项的叫法：环境检查「装到 iPhone 的方式」里叫「签名身份」「Xcode 账号」（Mac 上 Apple ID 只能经 Xcode 登录）
    var title: String? = nil
    var appleIdTitle: String? = nil
    var embedded = false
    @State private var confirmDelete = false

    private var on: Bool { model.devCert?.active == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if !embedded { LauncherRowIcon("signature") }
                Text(title ?? sx(loc, "title")).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                LauncherDropdown(options: [("xcode", appleIdTitle ?? sx(loc, "appleId")), ("certificate", sx(loc, "devcert"))],
                                 selection: on ? "certificate" : "xcode", label: title ?? sx(loc, "title")) {
                    model.setDevCertActive($0 == "certificate")
                }
                .launcherRowControls().controllerID("export.sign.mode")
            }
            if on, let cert = model.devCert?.cert { details(cert) }
            Text(sx(loc, "switchNote")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(embedded ? 0 : LauncherTheme.Metrics.cardInset)
        .background {
            if !embedded {
                RoundedRectangle(cornerRadius: LauncherTheme.Metrics.cardRadius).fill(LauncherTheme.Colors.card)
                    .overlay(RoundedRectangle(cornerRadius: LauncherTheme.Metrics.cardRadius).strokeBorder(LauncherTheme.Colors.border))
            }
        }
        .onAppear { model.refreshDevCert() }
        .onChange(of: model.selectedDevice?["udid"] as? String) { _ in model.refreshDevCert() }
        .sheet(isPresented: $model.showDevCertImport) { DevCertSheet(model: model).environmentObject(loc) }
        .alert(sx(loc, "deleteConfirm"), isPresented: $confirmDelete) {
            Button(sx(loc, "delete"), role: .destructive) { model.deleteDevCert() }
            Button(sx(loc, "sheet.cancel"), role: .cancel) {}
        }
    }

    private func details(_ c: DevCertInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            line(sx(loc, "team"), c.teamName.isEmpty ? c.teamId : "\(c.teamName)（\(c.teamId)）")
            line(sx(loc, "certExpires"), c.certExpires)
            line(sx(loc, "profileExpires"), c.profileExpires)
            line(sx(loc, "bundle"), c.bundleId)
            line(sx(loc, "devices"), devices(c))
            ForEach(c.blocking, id: \.self) { t in
                Label(loc.backend(t), systemImage: "xmark.octagon").font(LauncherTheme.TypeStyle.caption).foregroundStyle(LauncherPalette.danger).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(c.warnings, id: \.self) { t in
                Label(loc.backend(t), systemImage: "exclamationmark.triangle").font(LauncherTheme.TypeStyle.caption).foregroundStyle(.yellow).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(sx(loc, "replace")) { model.showDevCertImport = true }.controllerButtonStyle(LauncherSecondaryButtonStyle())
                    .accessibilityIdentifier("export.sign.replace")
                Button(sx(loc, "delete")) { confirmDelete = true }.controllerButtonStyle(LauncherSecondaryButtonStyle())
                    .accessibilityIdentifier("export.sign.delete")
            }
            .padding(.top, 4)
        }
        .padding(.leading, 28)
        .accessibilityIdentifier("export.sign.details")
    }

    private func devices(_ c: DevCertInfo) -> String {
        if c.allDevices { return sx(loc, "devices.all") }
        let key = c.deviceListed == nil ? "devices.unknown" : c.deviceListed == true ? "devices.listed" : "devices.missing"
        return sx(loc, key).replacingOccurrences(of: "{0}", with: String(c.deviceCount))
    }

    private func line(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(k).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(v.isEmpty ? "-" : v).font(.manrope(12.5, .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DevCertSheet: View {
    @ObservedObject var model: S2ArmLauncherModel
    @EnvironmentObject var loc: Localizer
    @Environment(\.dismiss) private var dismiss
    @State private var p12 = ""
    @State private var profile = ""
    @State private var password = ""
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LauncherSheetHeading(sx(loc, "sheet.title"))
            pick(sx(loc, "sheet.p12"), path: $p12, types: ["p12", "pfx"], id: "p12")
            pick(sx(loc, "sheet.profile"), path: $profile, types: ["mobileprovision"], id: "profile")
            VStack(alignment: .leading, spacing: 6) {
                Text(sx(loc, "sheet.password")).font(LauncherTheme.TypeStyle.section)
                SecureField("", text: $password).textFieldStyle(LauncherTextFieldStyle())
                    .accessibilityLabel(sx(loc, "sheet.password")).accessibilityIdentifier("export.sign.sheet.password")
                Text(sx(loc, "sheet.passwordNote")).font(LauncherTheme.TypeStyle.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let failure {
                Text(loc.backend(failure)).font(LauncherTheme.TypeStyle.detail).foregroundStyle(LauncherPalette.danger).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("export.sign.sheet.failure")
            }
            Spacer(minLength: 0)
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text(sx(loc, "sheet.working")).font(LauncherTheme.TypeStyle.detail).foregroundStyle(.secondary)
                }
                Spacer()
                Button(sx(loc, "sheet.cancel")) { dismiss() }.controllerButtonStyle(LauncherSecondaryButtonStyle()).keyboardShortcut(.cancelAction).controllerShortcut(.back)
                Button(sx(loc, "sheet.import")) { start() }
                    .controllerButtonStyle(LauncherPrimaryButtonStyle()).keyboardShortcut(.defaultAction).controllerShortcut(.rightTrigger)
                    .disabled(working || p12.isEmpty || profile.isEmpty)
                    .accessibilityIdentifier("export.sign.sheet.import")
            }
        }
        .padding(LauncherTheme.Space.page)
        .launcherSheet(.form, height: 520)
    }

    private func start() {
        working = true; failure = nil
        Task {
            let why = await model.importDevCert(p12: p12, profile: profile, password: password)
            working = false
            if let why { failure = why } else { password = ""; dismiss() }
        }
    }

    private func pick(_ title: String, path: Binding<String>, types: [String], id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(LauncherTheme.TypeStyle.section)
            HStack(spacing: 10) {
                Text(path.wrappedValue.isEmpty ? sx(loc, "sheet.drop") : (path.wrappedValue as NSString).abbreviatingWithTildeInPath)
                    .font(LauncherTheme.TypeStyle.detail).foregroundStyle(path.wrappedValue.isEmpty ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(sx(loc, "sheet.choose")) {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
                    panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
                }
                .controllerButtonStyle(LauncherSecondaryButtonStyle())
                .accessibilityIdentifier("export.sign.sheet.choose." + id)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .launcherPanel()
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let item = providers.first else { return false }
                _ = item.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, types.contains(url.pathExtension.lowercased()) else { return }
                    DispatchQueue.main.async { path.wrappedValue = url.path }
                }
                return true
            }
        }
    }
}
