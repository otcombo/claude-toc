import SwiftUI
import AppKit
import UserNotifications

struct OnboardingView: View {
    @State private var isAccessibilityGranted = AXIsProcessTrusted()
    @State private var notificationStatus: NotificationStatus = .unknown
    @State private var pollTimer: Timer?
    @State private var hasClickedPermission = false
    @State private var pollsSinceClick = 0
    @State private var isPresented = false

    enum NotificationStatus {
        case unknown, granted, denied, notDetermined
    }

    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                if let iconURL = Bundle.main.url(forResource: "appicon64@3x", withExtension: "png"),
                   let nsImage = NSImage(contentsOf: iconURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                }

                Text("开启权限，解锁完整体验")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.black)

                VStack(spacing: 10) {
                    // Accessibility permission row
                    Button(action: {
                        hasClickedPermission = true
                        pollsSinceClick = 0
                        openAccessibilitySettings()
                    }) {
                        permissionRow(
                            icon: "checklist",
                            title: "辅助功能",
                            subtitle: "点击标题自动定位到终端对应位置",
                            required: true,
                            granted: isAccessibilityGranted
                        )
                    }
                    .buttonStyle(.plain)

                    // Notification permission row
                    Button(action: {
                        requestNotificationPermission()
                    }) {
                        permissionRow(
                            icon: "app.badge",
                            title: "通知",
                            subtitle: "终端切到后台时收到 Claude 回复提醒",
                            required: false,
                            granted: notificationStatus == .granted
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(notificationStatus == .granted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Spacer().frame(height: 24)

            // Footer
            Button(action: {
                if shouldOfferRelaunch || isAccessibilityGranted {
                    relaunchApp()
                }
            }) {
                Text(footerButtonTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background(Color.black)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(footerButtonDisabled ? 0.4 : 1.0)
            .disabled(footerButtonDisabled)
        }
        .padding(28)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 32, x: 0, y: 16)
        .scaleEffect(isPresented ? 1.0 : 0.92)
        .opacity(isPresented ? 1.0 : 0.0)
        .padding(.horizontal, 50)
        .padding(.top, 50)
        .padding(.bottom, 80)
        .onAppear {
            startPolling()
            checkNotificationStatus()
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
            return "开始使用"
        } else if shouldOfferRelaunch {
            return "重启应用"
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

    // MARK: - Reusable Row

    private func permissionRow(icon: String, title: String, subtitle: String, required: Bool, granted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .frame(width: 32, height: 32)
                .foregroundColor(.black.opacity(0.8))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.black.opacity(0.8))
                    if required {
                        Text("*")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.red)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.black.opacity(0.4))
            }

            Spacer()

            if granted {
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
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(granted ? Color.green.opacity(0.05) : Color.black.opacity(0.03))
        )
    }

    // MARK: - Actions

    private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func requestNotificationPermission() {
        if notificationStatus == .notDetermined || notificationStatus == .unknown {
            // First time: system dialog will appear
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                DispatchQueue.main.async {
                    notificationStatus = granted ? .granted : .denied
                }
            }
        } else {
            // Already decided: open system settings to let user change
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
        }
    }

    private func checkNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async {
                switch status {
                case .authorized, .provisional:
                    notificationStatus = .granted
                case .denied:
                    notificationStatus = .denied
                case .notDetermined:
                    notificationStatus = .notDetermined
                @unknown default:
                    notificationStatus = .unknown
                }
            }
        }
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

                    // Also poll notification status
                    checkNotificationStatus()

                    if granted && notificationStatus != .notDetermined && notificationStatus != .unknown {
                        pollTimer?.invalidate()
                        pollTimer = nil
                    }
                }
            }
        }
    }
}
