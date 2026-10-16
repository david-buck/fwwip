# FWWIP

A lightweight native Mac panel for keeping current Fieldwerk work in view. Fieldwerk remains the source of truth: FWWIP reads canonical memos and can move a card between board columns without keeping a separate task database.

This is a personal, early-stage app built with SwiftUI and AppKit. It is not an official Fieldwerk client.

## What it does

- Lives in the menu bar and opens a compact, resizable panel with an optional Always on Top setting.
- Lets you choose a workspace and collection, then browse one board column at a time. Use the arrows or **⌥⌘← / ⌥⌘→** to cycle columns.
- Shows task links, explicitly authored progress updates with timestamps, verified evidence and conversation links when available.
- Filters confirmed requests with **Needs you**. Missing action metadata remains unknown.
- Provides optimistic **Move to**, native Undo/Redo, version checks, conflict reporting and canonical read-back.

Closing the panel keeps FWWIP running. Use the menu-bar menu to show it again or quit. Workspace, collection and column choices are saved locally.

## Build and run

The current Xcode project targets **macOS 26.7.1** and has been built with **Xcode 27.0**. It uses Apple frameworks without third-party package dependencies.

1. Open `fwwip.xcodeproj` in Xcode.
2. Select the **fwwip** scheme and **My Mac** destination.
3. Choose your own development team in Signing & Capabilities. Use your own bundle identifier when building a separate installation.
4. Run the app and choose **Connect to Fieldwerk**. Review the access and storage choices, then complete sign-in in your browser.

For a command-line build after configuring signing:

```sh
xcodebuild -project fwwip.xcodeproj -scheme fwwip -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/fwwip-build build
```

The app is built at `/tmp/fwwip-build/Build/Products/Debug/fwwip.app`. Persistent sign-in uses the app's private Data Protection Keychain item and requires correctly configured signing and entitlements. Changing the signing identity or bundle identifier may require a new sign-in.

## Fieldwerk connection

FWWIP connects directly to the official Streamable HTTP MCP endpoint at `https://mcp.fieldwerk.ai/mcp`. It validates public OAuth discovery, registers a public client after explicit approval, and uses authorization code flow with S256 PKCE and state validation. The loopback callback is fixed at `http://127.0.0.1:53682/oauth/callback`; that port must be available during sign-in.

The implementation requests `memos:rw`, the scope advertised by the provider during development. The connection screen discloses read/write access. You can keep tokens in memory until quit or explicitly remember sign-in in the device-only Keychain, without iCloud synchronization. The app uses its own credentials and never imports another app's session. Sign out removes its saved tokens and attempts remote revocation.

There is no hosted backend, telemetry service or persistent task cache in this project. Network sessions are ephemeral and disable cookies, shared credentials, caching and redirects. Local preferences store selections and public OAuth client registration metadata; tokens use the chosen memory/Keychain storage.

## Boards and moves

For each collection, FWWIP chooses **Active work** when present, otherwise **Work board**, otherwise the first collection-level board. It uses the view's actual filters, grouping field, scope and column configuration. Configured empty columns stay available, explicitly hidden columns remain hidden, and cards retain the order returned by Fieldwerk within each column.

Matching memo pages are read into memory to establish columns and counts. The panel displays 50 filtered cards at a time, with **Show more** when more cards remain.

Card moves currently support **memo-scoped select properties**. FWWIP re-reads the board and memo, checks the source column and current version, then changes only the grouping field using `base_version`. It omits collection overrides and overwrite flags. **Not set** removes the property using versioned `delete_field`. The card appears in the destination immediately and counts update while the write runs in the background. Writes are serialized per canonical card, with up to three independent cards processed concurrently. Rapid moves remain queued in order for each card. Other cards, columns, workspace/collection navigation and refresh remain interactive. Pending projections and read guards are scoped to the originating workspace and collection so old responses cannot replace newer state. Success requires a matching read-back with unrelated data preserved and a successful board refresh. A failed request removes only its own pending projection, refetches authoritative state and preserves newer queued placements. Queued moves still check their expected source, so a conflict can independently refuse a later move rather than overwrite an external change. Uncertain results show **Move not confirmed**; a conflict is not forcibly overwritten.

Current limits:

- Custom-sort, notebook-grouped and file-inclusive boards are unsupported.
- Collection-scoped moves are unavailable because their property writes have no version counter.
- A grouping-field collection override blocks a move; resolve it in Fieldwerk first.
- Project reassignment stays in Fieldwerk because home membership must also be reconciled.
- Non-select grouping properties stay in Fieldwerk. The app does not create columns, change schemas, edit task bodies, alter sharing or reconcile memberships.

The latest verified move in this session can be undone with **Cmd-Z / Edit → Undo Move Card** and redone with **Cmd-Shift-Z / Edit → Redo Move Card**. The exact prior value, including absence or a literal empty string, is retained with memo scope, collection overrides and the confirmed post-write version. Each inverse checks that version and state before writing only the same property. A pending inverse disables only its own Undo/Redo entry until verified; unrelated card operations stay interactive. Failed writes create no durable history, and a new move clears redo immediately. History is in memory and is cleared at sign-out or quit. Collection-scoped writes remain unsupported because they lack version protection.

Collection instructions and status meanings still apply. Moving to Done does not create completion evidence.

## Optional progress and action metadata

Activity timestamps, status and documentation sync fields are not treated as meaningful progress or requests for action. FWWIP reads these optional, explicitly authored memo properties:

| Property | JSON type | Meaning |
| --- | --- | --- |
| `wip_update` | string | A concrete progress update |
| `wip_occurred_at` | ISO 8601 string | When the result happened |
| `wip_verified_at` | ISO 8601 string | When its evidence was checked |
| `wip_evidence_url` | HTTPS string | Source supporting the update/action assertion |
| `wip_needs_user` | boolean | Explicit action/no-action assertion |
| `wip_action_reason` | string | The confirmed reason |
| `wip_action_recipient` | string | Currently must be exactly `David` |
| `wip_conversation_url` | HTTPS string | Associated conversation |
| `wip_conversation_verified_at` | ISO 8601 string | Independent conversation verification time |

Progress requires text, occurrence time, verification time and evidence. Attention requires verification/evidence, a real boolean, a reason and the exact recipient. Missing or invalid values stay unknown; false is not the default. Conversation links require their own verification. Future verification dates, occurrence dates after verification, and URLs containing credentials or nonstandard ports are rejected. These are authored assertions, not automatic verification of remote evidence. FWWIP does not create or backfill these properties.

The recipient check is deliberately personal; this prototype is not a general multi-user action resolver. Test fixtures are synthetic and never appear as live sample cards in the normal interface.

## Tests and verification status

Run the core tests on macOS:

```sh
swift test
```

The 69 tests cover OAuth validation, PKCE/callback binding, real loopback listener cleanup, read-tool restrictions, canonical links, typed metadata, selection persistence, column grouping/order, pagination, move validation/conflict/read-back behavior, exact-value undo/redo, optimistic counts, rapid moves, rollback, and stale-completion isolation. Loopback tests bind `127.0.0.1:53682`; stop any active sign-in first and allow local loopback access. Tests do not perform real login or read real Keychain credentials.

The signed app build and all 69 core tests have passed locally. Native optimistic Move to, Cmd-Z and Cmd-Shift-Z were observed on a temporary synthetic fixture and confirmed by canonical read-back. An intervening remote version change was refused by native Undo, with a concise error and authoritative refetch. The fixture was restored and recoverably archived. The quiet interface was inspected after relaunch: routine operation messages and inline Undo/Redo controls are absent. Bounded concurrency, rapid intent ordering and workspace/collection read races are covered by automated tests; not every concurrent UI scenario has been exercised manually.

Routine move, saving, undo and redo status is deliberately absent from the visible interface; the card position is the feedback. Concise errors remain visible when a write or authoritative refresh fails.

This repository contains app source and synthetic tests. Private workspace data, development screenshots, logs, credentials and local evidence are excluded. There is no packaged, notarized release yet.
