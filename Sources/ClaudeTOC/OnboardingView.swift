import SwiftUI
import AppKit

struct OnboardingView: View {
    @State private var isAccessibilityGranted = AXIsProcessTrusted()
    @State private var pollTimer: Timer?
    @State private var hasClickedPermission = false
    @State private var pollsSinceClick = 0
    @State private var isPresented = false

    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 14)

            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("系统权限")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.black)

                    Text("ClaudeTOC 需要辅助功能权限来读取终端窗口内容。\n点击下方打开系统设置，授权后自动检测。")
                        .font(.system(size: 14))
                        .foregroundColor(.black.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Accessibility permission row
                Button(action: {
                    hasClickedPermission = true
                    pollsSinceClick = 0
                    openAccessibilitySettings()
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: "hand.raised")
                            .font(.system(size: 20))
                            .frame(width: 32, height: 32)
                            .foregroundColor(.black)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 2) {
                                Text("辅助功能")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.black)
                                Text("*")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.red)
                            }
                            Text("读取终端窗口位置、跟踪窗口焦点")
                                .font(.system(size: 11))
                                .foregroundColor(.black.opacity(0.4))
                        }

                        Spacer()

                        if isAccessibilityGranted {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.green)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.black.opacity(0.3))
                        }
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 14)
                    .padding(.vertical, 13)
                    .frame(height: 58)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isAccessibilityGranted ? Color.green.opacity(0.05) : Color.black.opacity(0.03))
                    )
                }
                .buttonStyle(.plain)

                // Hint text
                HStack(spacing: 4) {
                    Image(systemName: shouldOfferRelaunch ? "exclamationmark.triangle" : "info.circle")
                        .font(.system(size: 11))
                    if isAccessibilityGranted {
                        Text("权限已开启，授权后需要重启应用才能生效。")
                            .font(.system(size: 11))
                    } else if shouldOfferRelaunch {
                        Text("权限授权后需要重启应用才能生效")
                            .font(.system(size: 11))
                    } else {
                        Text("授权后可能需要重启应用才能生效")
                            .font(.system(size: 11))
                    }
                }
                .foregroundColor(shouldOfferRelaunch || isAccessibilityGranted ? .orange : .black.opacity(0.35))
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 12)

            Spacer(minLength: 12)

            // Footer
            HStack {
                Spacer()

                Button(action: {
                    if shouldOfferRelaunch || isAccessibilityGranted {
                        relaunchApp()
                    }
                }) {
                    Text(footerButtonTitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .frame(minWidth: 100, minHeight: 36)
                        .background(Color.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .opacity(footerButtonDisabled ? 0.4 : 1.0)
                .disabled(footerButtonDisabled)
            }
            .padding(.top, 12)
        }
        .padding(12)
        .frame(width: 420, height: 320)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 32, x: 0, y: 16)
        .scaleEffect(isPresented ? 1.0 : 0.92)
        .opacity(isPresented ? 1.0 : 0.0)
        .padding(.horizontal, 50)
        .padding(.top, 44)
        .padding(.bottom, 92)
        .onAppear {
            startPolling()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                isPresented = true
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
        }
    }

    // MARK: - Footer

    private var footerButtonTitle: String {
        if isAccessibilityGranted {
            return "退出并重新打开"
        } else if shouldOfferRelaunch {
            return "退出并重新打开"
        } else {
            return "请先开启权限"
        }
    }

    private var footerButtonDisabled: Bool {
        !isAccessibilityGranted && !shouldOfferRelaunch
    }

    private var shouldOfferRelaunch: Bool {
        hasClickedPermission && !isAccessibilityGranted && pollsSinceClick >= 5
    }

    // MARK: - Actions

    private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let granted = AXIsProcessTrusted()
                    isAccessibilityGranted = granted

                    if hasClickedPermission && !granted {
                        pollsSinceClick += 1
                    }

                    if granted {
                        pollTimer?.invalidate()
                        pollTimer = nil
                    }
                }
            }
        }
    }
}
