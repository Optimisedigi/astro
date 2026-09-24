import Foundation

/// Schedule tools — descriptions extracted verbatim from Tama's binary (SPEC.md §2).

private func param(_ input: [String: Any], _ key: String) throws -> String {
    guard let value = input[key] as? String, !value.isEmpty else { throw ToolError.missingParam(key) }
    return value
}

struct CreateReminderTool: AgentTool {
    let name = "create_reminder"
    let description = #"Create a reminder that will fire a macOS notification at the scheduled time. Supports: "30m", "45 minutes", "in an hour", "9:15pm", "at 4pm", "every 2h", "tomorrow 3pm", "in 10 minutes", cron expressions (e.g. "0 9 * * *"). Times are worked out from this Mac's clock, so pass the user's time as they said it and never ask them what time it is now. For "in 1 hour 30 minutes" pass "90m". The result's next_run and now are in the user's local time; if the schedule can't be parsed, use now to work out a supported form and try again instead of asking."#
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "name": ["type": "string", "description": "Short name for the reminder"],
            "message": ["type": "string", "description": "Notification body text"],
            "schedule": ["type": "string", "description": "When to fire, e.g. \"45 minutes\", \"9:15pm\", \"tomorrow 3pm\", \"0 9 * * *\""],
        ],
        "required": ["name", "message", "schedule"],
    ]

    func run(input: [String: Any], workingDirectory: URL) async throws -> String {
        let name = try param(input, "name")
        let message = try param(input, "message")
        let schedule = try param(input, "schedule")
        return await MainActor.run {
            ScheduleStore.shared.create(name: name, kind: .reminder, schedule: schedule, message: message)
        }
    }
}

struct CreateRoutineTool: AgentTool {
    let name = "create_routine"
    let description = #"Create a routine that runs an LLM prompt on a schedule. The prompt is executed by the agent and the result is delivered as a macOS notification. Supports: "every 2h", "0 9 * * *" (cron), "tomorrow 3pm", "in 10 minutes"."#
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "name": ["type": "string", "description": "Short name for the routine"],
            "prompt": ["type": "string", "description": "The prompt the agent runs on each firing"],
            "schedule": ["type": "string", "description": "When to run, e.g. \"every 2h\", \"0 9 * * *\""],
        ],
        "required": ["name", "prompt", "schedule"],
    ]

    func run(input: [String: Any], workingDirectory: URL) async throws -> String {
        let name = try param(input, "name")
        let prompt = try param(input, "prompt")
        let schedule = try param(input, "schedule")
        return await MainActor.run {
            ScheduleStore.shared.create(name: name, kind: .routine, schedule: schedule, message: prompt)
        }
    }
}

struct ListSchedulesTool: AgentTool {
    let name = "list_schedules"
    let description = "List all active scheduled reminders and routines with their next run times."
    let inputSchema: [String: Any] = ["type": "object", "properties": [:]]

    func run(input: [String: Any], workingDirectory: URL) async throws -> String {
        await MainActor.run { ScheduleStore.shared.list() }
    }
}

struct DeleteScheduleTool: AgentTool {
    let name = "delete_schedule"
    let description = "Delete a scheduled reminder or routine by name."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": ["name": ["type": "string", "description": "Name of the schedule to delete"]],
        "required": ["name"],
    ]

    func run(input: [String: Any], workingDirectory: URL) async throws -> String {
        let name = try param(input, "name")
        return await MainActor.run { ScheduleStore.shared.delete(name: name) }
    }
}
