import SwiftUI
import AppKit

struct UpdateView: View {
    @ObservedObject var state: UpdateViewState

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 28)

            // App icon
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 80, height: 80)
            }

            Spacer().frame(height: 16)

            // App name
            Text("TOC for Claude Code")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)

            Spacer().frame(height: 6)

            // Current version
            Text("v\(state.currentVersion)")
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundColor(.secondary)

            Spacer().frame(height: 24)

            // Status area
            Group {
                if state.isUpdating {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在更新…")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                } else if state.isChecking {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在检查更新…")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                } else if state.updateAvailable, let latest = state.latestVersion {
                    VStack(spacing: 12) {
                        Text("新版本 v\(latest) 可用")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary)

                        Button(action: { Updater.shared.performUpdate() }) {
                            Text("更新并重启")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)
                                .frame(minHeight: 32)
                                .background(Color.accentColor)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                } else if state.checkFailed {
                    VStack(spacing: 12) {
                        Text("检查更新失败")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)

                        Button(action: { Updater.shared.checkForUpdate(silent: false) }) {
                            Text("重试")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("已是最新版本")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }

            Spacer().frame(height: 28)
        }
        .frame(width: 280)
        .fixedSize(horizontal: true, vertical: true)
    }
}

/// Observable state that the Updater pushes into
class UpdateViewState: ObservableObject {
    @Published var currentVersion: String = ""
    @Published var latestVersion: String?
    @Published var isChecking = false
    @Published var isUpdating = false
    @Published var updateAvailable = false
    @Published var checkFailed = false
}
