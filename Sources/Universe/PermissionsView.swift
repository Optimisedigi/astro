import SwiftUI

/// The Permissions sheet: what macOS has granted, and one tap to fix each gap.
struct PermissionsView: View {
    @ObservedObject var checker: PermissionsChecker
    var onDone: () -> Void = {}

    var body: some View {
        SettingsSheet(title: "Permissions") {
            PermissionsBody(checker: checker)
        } footer: {
            Button("Refresh") { Task { await checker.refresh() } }
                .disabled(checker.isRefreshing)
            Spacer()
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
    }
}

struct PermissionsBody: View {
    @ObservedObject var checker: PermissionsChecker

    var body: some View {
        SettingsSheetBody {
            ForEach(checker.permissions) { permission in
                PermissionRow(permission: permission) { checker.grant(permission.kind) }
                if permission.id != checker.permissions.last?.id { Divider() }
            }
        }
    }
}

struct PermissionRow: View {
    let permission: PermissionsChecker.Permission
    var action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).fontWeight(.semibold)
                Text(permission.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(permission.title). \(accessibilityStatus). \(permission.reason)")
    }

    @ViewBuilder
    private var control: some View {
        switch permission.status {
        case .granted:
            StatusPill(text: "Granted", tone: .good)
        case .ready(let detail):
            VStack(alignment: .trailing, spacing: 2) {
                StatusPill(text: "Ready", tone: .good)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        case .denied:
            Button(permission.optional ? "Get" : "Grant", action: action)
        case .unknown:
            // Never claim a permission is granted when macOS will not say.
            Button("Check", action: action)
        }
    }

    private var accessibilityStatus: String {
        switch permission.status {
        case .granted: return "Granted"
        case .ready(let detail): return detail
        case .denied: return "Not granted"
        case .unknown: return "Status unknown, needs checking"
        }
    }
}
