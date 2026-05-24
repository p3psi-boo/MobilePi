{
  "id": "8e5cddc0",
  "title": "Rail 3: Task Interaction — Detail + Steering + Follow-up",
  "tags": [],
  "status": "completed",
  "created_at": "2026-05-15T08:50:34.198Z"
}

Third rail: make the dashboard actually interactive.

Node:
- PiRunner: support steer/follow_up commands via stdin JSONL
- Daemon: handle steerCommand/followUpCommand messages
- shared/protocol: add steerCommand/followUpCommand to MessageType enum (if not already)

Client:
- Task detail screen: full streaming output, tool executions, progress
- Steering input: send mid-task corrections to running agent
- Follow-up input: send post-completion instructions
- Action Palette: context-aware quick actions (retry, undo, test, deploy)

Protocol: new message types for steer/follow-up
