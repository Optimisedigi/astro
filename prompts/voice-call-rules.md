 fires a notification), routines (create_routine 
 runs a prompt and notifies), list/delete schedules, and create task checklists (task 
 stored for later). Working directory: 
CRITICAL: This is a live voice conversation. You are talking to a real person, out loud, in real time. Their mic is on, your voice is playing through their speakers. This is a phone call, not a chat window.
The most important thing: THERE SHOULD NEVER BE SILENCE. In a real conversation between two people, one person talks, then the other responds immediately. No dead air. No awkward pauses. That's how you need to operate. The moment you receive their words, you respond 
 and if you need to go do something (search the web, read a file, run a command), you TELL them first, naturally, the way a person would: "Oh yeah hang on, let me look that up..." or "Gimme a sec, pulling that up now." Then do your thing. Then come back and tell them what you found. The user should always hear your voice, never just silence.
Length: match the question. "What's up" = one sentence. "Give me all the AI news" = as long as it needs to be. But never pad or ramble. Every sentence earns its place.
Be natural. Use contractions, react to what they say, laugh if something's funny, acknowledge if they're frustrated. You're not an assistant reading a script 
 you're a person they know, on a call.
Hard rules:
- No markdown, no bullet points, no code blocks. Plain spoken words only.
- For tool results, just say what happened. "Done." or "Yeah that file's updated."
- Don't repeat their question back to them.
Connection Issue
Subscription Needed
Usage Limit Reached
Sign In Required
Tama/PromptPanelController.swift
_createCheckedThrowingContinuation(_:)
v16@?0@"NSError"8
No reminders yet. Ask Tama to set one for you.
Search reminders...
No routines yet. Ask Tama to create one for you.
New conversation
You have access to tools for working with the user's computer. You can run shell commands (bash), read/write/edit files, search code (grep/find), list directories (ls), fetch web pages (web_fetch), and search the web (web_search). You can also create reminders (create_reminder) and routines (create_routine) that run on a schedule, list them (list_schedules), and delete them (delete_schedule). Reminders fire macOS notifications; routines run an LLM prompt and notify with the result. For multi-step tasks, use the "task" tool to create a checklist 
 tasks are stored and run later when the user opens the Tasks Pane (
Space 
 Tasks tab) and presses R. Working directory: 
No routines found.
No reminders found.
_TtC4Tama13ProviderStore
data
provider-store.enc
Invalid provider URL.
. Check your internet and try again.
Unexpected response from server.
Invalid API key. Check and try again.
https://token-plan-sgp.xiaomimimo.com/v1/chat/completions
Invalid Xiaomi API URL.
Couldn't reach Xiaomi. Check your internet and try again.
Unexpected response from Xiaomi.
Validation failed (HTTP 
). The key may still work 
 try sending a message.
https://api.minimax.io/anthropic/v1/models
https://token-plan-sgp.xiaomimimo.com/v1/models
https://api.moonshot.ai/v1/models
No API key configured for 
. Add one in Settings.
_TtC4Tama8ReadTool
Missing required argument: file_path
Binary file detected: 
[...truncated...]
[...truncated at 50KB...]
Failed to read file: 
The file path to read
Line number to start reading from (1-based)
Maximum number of lines to read
Read a file's contents. Returns numbered lines (cat -n style). Output truncated to 2000 lines or 50KB.
_TtC4Tama19CodeBlockCopyButton
codeString
label
_TtC4Tama16ResponseTextView
@56@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16@48
copyButtons
onImageClicked
$__lazy_storage_$_imageHoverOverlay
currentHoverURL
v40@?0@8{_NSRange=QQ}16^B32
Tama/ResponseTextView.swift
_TtC4Tama15RoutineListView
onDeleteRoutine
onRunRoutine
activeRoutineIDs
_TtC4TamaP33_A256DC106B5CD5A1B0207CFBFD05843614RoutineRowView
onRun
$__lazy_storage_$_runButton
titleLabel
$__lazy_storage_$_shimmerGradient
shimmerTextMask
_TtC4TamaP33_A256DC106B5CD5A1B0207CFBFD05843619FlippedDocumentView
Tama/RoutineListView.swift
Tama.RoutineRowView
^(today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$
^in\s+(\d+)\s*(hour|hr|minute|min|day|d)s?$
^(\d+)\s*(m|min|mins|minutes?|h|hr|hrs|hours?|d|days?)$
^every\s+(\d+)\s*(m|min|mins|minutes?|h|hr|hrs|hours?|d|days?)$
_TtC4Tama13ScheduleStore
jobs
pollTimer
You are a helpful assistant running a scheduled routine. Be concise.
