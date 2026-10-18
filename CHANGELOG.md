# Changelog

## Unreleased

- Remove the custom WIP metadata reader and Needs you filter. Existing Fieldwerk card fields are left untouched.
- Keep workspace and collection selectors and Last synced in the main panel; put connection diagnostics and service-connection controls under the menu-bar Connection details submenu. Remove the Details control from the panel while keeping useful errors visible. Rename Fetched to Last synced.
- Use the supplied AppIconFW Icon Composer package as the app’s main icon.
- Use full-width native workspace and collection pop-up controls without visible field labels.
- Enable Hardened Runtime for Debug and Release, and set the macOS Productivity app category. Verify a signed universal Release archive without adding runtime entitlement exceptions.
- Add **Trash** after a separator in Move to, using Fieldwerk’s recoverable claimed-owner trash operation.
- Reuse optimistic removal, per-card serialization, concise failure feedback and native Undo/Redo for restore/re-trash. Preserve canonical fields, memberships, sharing and archive state.
- Refuse unclaimed/unowned cards and repeat deletion of already-trashed cards; never automatically replay trash/restore requests. The backend provides preflight/read-back protection rather than an atomic `base_version` condition for these operations.
- Add synthetic success, rejection, rollback, restore, redo, ownership and queued-removal coverage. No multi-selection UI or permanent-delete action is added.

## 2026-10-16

- Move cards optimistically: update their column and counts immediately, then verify the canonical Fieldwerk write in the background.
- Serialize changes per canonical card, with up to three independent cards processed concurrently. Keep other cards and workspace, collection and column navigation interactive.
- Scope pending projections and refresh guards to their originating workspace/collection. Older completions cannot roll back newer intent or replace newer reads.
- Add native **Edit → Undo Move Card / Redo Move Card**, **Cmd-Z** and **Cmd-Shift-Z** for the latest verified move. Preserve exact prior values, including absent and empty properties, and refuse inverse writes after intervening remote changes.
- Refetch authoritative state on failure, roll back only the affected current operation and show concise errors. New moves clear redo; failed writes create no durable undo history.
- Remove routine saving, success, undo and redo banners and inline controls. Keep nonvisual accessibility announcements and native menu commands.
- Preserve existing OAuth permissions, private Keychain storage, unrelated memo fields, memberships and sharing. Collection-scoped moves remain unsupported because their writes lack version protection.

Validation: signed local Debug build and 69 core tests passed. Native move, undo, redo, conflict refusal and the quiet panel were inspected with a temporary synthetic fixture. Concurrent scheduling and context races have automated coverage; full manual coverage of every concurrent UI scenario is not claimed. No packaged or notarized release is included.
