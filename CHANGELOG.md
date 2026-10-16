# Changelog

## 2026-10-16

- Move cards optimistically: update their column and counts immediately, then verify the canonical Fieldwerk write in the background.
- Serialize changes per canonical card, with up to three independent cards processed concurrently. Keep other cards and workspace, collection and column navigation interactive.
- Scope pending projections and refresh guards to their originating workspace/collection. Older completions cannot roll back newer intent or replace newer reads.
- Add native **Edit → Undo Move Card / Redo Move Card**, **Cmd-Z** and **Cmd-Shift-Z** for the latest verified move. Preserve exact prior values, including absent and empty properties, and refuse inverse writes after intervening remote changes.
- Refetch authoritative state on failure, roll back only the affected current operation and show concise errors. New moves clear redo; failed writes create no durable undo history.
- Remove routine saving, success, undo and redo banners and inline controls. Keep nonvisual accessibility announcements and native menu commands.
- Preserve existing OAuth permissions, private Keychain storage, unrelated memo fields, memberships and sharing. Collection-scoped moves remain unsupported because their writes lack version protection.

Validation: signed local Debug build and 69 core tests passed. Native move, undo, redo, conflict refusal and the quiet panel were inspected with a temporary synthetic fixture. Concurrent scheduling and context races have automated coverage; full manual coverage of every concurrent UI scenario is not claimed. No packaged or notarized release is included.
