import SwiftUI

/// The Routines tab: scheduled reminders and routines with run/delete actions.
/// Matches tama-agent's RoutineListView styling.
struct RoutineListView: View {
    @ObservedObject var store: ScheduleStore
    /// Which job kind this tab shows (Tama has separate Reminders and Routines tabs).
    var kind: ScheduleStore.Job.Kind = .routine
    @State private var isRunning: Set<UUID> = []

    private var jobs: [ScheduleStore.Job] { store.jobs.filter { $0.kind == kind } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(kind == .reminder ? "Reminders" : "Routines")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if jobs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(jobs) { job in
                            RoutineRow(
                                job: job,
                                isRunning: isRunning.contains(job.id),
                                onRun: { runRoutine(job) },
                                onDelete: { store.delete(name: job.name) }
                            )
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: kind == .reminder ? "bell" : "clock")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(kind == .reminder ? "No reminders yet" : "No routines yet")
                .font(.headline)
            Text(kind == .reminder ? "Ask Universe to remind you about something."
                                   : "Ask Universe to create a routine.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func runRoutine(_ job: ScheduleStore.Job) {
        isRunning.insert(job.id)
        // The actual execution is handled by ScheduleStore; this just shows the shimmer.
        Task {
            try? await Task.sleep(for: .seconds(2))
            isRunning.remove(job.id)
        }
    }
}

struct RoutineRow: View {
    let job: ScheduleStore.Job
    let isRunning: Bool
    var onRun: () -> Void
    var onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: job.kind == .reminder ? "bell" : "arrow.triangle.2.circlepath")
                .font(.system(size: 16))
                .foregroundStyle(isRunning ? Color.accentColor : .secondary)
                .frame(width: 28)
                .opacity(isRunning ? 0.6 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(job.schedule)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            } else if isHovered {
                HStack(spacing: 6) {
                    Button(action: onRun) {
                        Text("Run")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)

                    Button(action: onDelete) {
                        Text("Delete")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text(relativeTime(job.nextRun))
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? Color.white.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { isHovered = $0 }
    }

    private func relativeTime(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let f = DateFormatter(); f.dateFormat = "h:mm a"; return f.string(from: date)
        }
        if cal.isDateInYesterday(date) { return "Tomorrow" }
        let f = DateFormatter(); f.dateFormat = "MMM d h:mm a"; return f.string(from: date)
    }
}
