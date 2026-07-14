# TaskLite — product brief

TaskLite is a lightweight task tracker for one small team that wants a shared,
no-ceremony view of who is doing what.

Users create tasks with a **title** and an optional **description**, list all tasks
grouped by status (**To Do** / **Done**), mark tasks as done (and back to To Do), and
delete tasks that are no longer needed. Tasks must not be lost when the application
restarts.

All of this happens through TaskLite's **public API**: the same core actions —
creating, listing, completing, and deleting tasks — are available to people,
scripts, and other tools alike.

TaskLite runs self-contained: no external services or databases to operate.

Version 1 is intentionally small: one shared task list, **no user accounts, no
login, no notifications**. Out of scope for version 1: a web UI, multiple boards,
assignees, due dates, attachments.
