# FWWIP

A lightweight native Mac panel for keeping current Fieldwerk work in view. Fieldwerk remains the source of truth: FWWIP reads canonical memos and can move a card between board columns without keeping a separate task database.

This is a personal, early-stage app built with SwiftUI and AppKit. It is not an official Fieldwerk client.

## What it does

- Lives in the menu bar and opens a compact, resizable panel with an optional Always on Top setting.
- Lets you choose a workspace and collection in the main panel, then browse one board column at a time. Use the arrows or **⌥⌘← / ⌥⌘→** to cycle columns.
- Shows canonical task links and each card’s current Fieldwerk status.
- Provides optimistic **Move to**, native Undo/Redo, version checks, conflict reporting and canonical read-back.

Closing the panel keeps FWWIP running. Use the menu-bar menu to show it again or quit. **Connection details** in the menu-bar menu contains sign-in and sign-out, connection status, the last sync time and errors. Workspace and collection selectors remain in the main panel. Workspace, collection and column choices are saved locally.

## Build and run

The app targets **macOS 15.6 or later** and has been built with **Xcode 27.1**. It uses Apple frameworks without third-party package dependencies.

1. Open `fwwip.xcodeproj` in Xcode.
2. Select the **fwwip** scheme and **My Mac** destination.
3. Choose your own development team in Signing & Capabilities. Use your own bundle identifier when building a separate installation.
4. Run the app, open the FWWIP menu-bar menu, then choose **Connect to Fieldwerk** under **Connection details**. Review the access and storage choices, then complete sign-in in your browser.

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

**Trash** appears after a divider in the Move to menu. It uses Fieldwerk’s existing recoverable trash/restore operations, not a status, collection, archive shortcut or permanent-delete feature. The app first verifies that the card is live, filed in the selected collection and listed among the signed-in account’s owned memos; unclaimed or unowned memos are refused. It removes the card optimistically using the same per-card queue, rolls back/refetches on failure, and records **Undo Trash Card / Redo Trash Card** only after verification. Restore preserves the prior archive state, fields, memberships and sharing. The interface supports individual cards, not multi-selection.

Fieldwerk controls the plan-dependent recovery window. Its MCP trash/restore calls do not accept `base_version`, so the app rechecks ownership/state and verifies results but cannot provide an atomic version condition for those calls. It never automatically replays a trash/restore request and never deletes an already-trashed memo a second time. Restore/redo refuse unexpected state or version changes. The normal field-move version checks are unchanged.

Current limits:

- Custom-sort, notebook-grouped and file-inclusive boards are unsupported.
- Collection-scoped moves are unavailable because their property writes have no version counter.
- A grouping-field collection override blocks a move; resolve it in Fieldwerk first.
- Project reassignment stays in Fieldwerk because home membership must also be reconciled.
- Non-select grouping properties stay in Fieldwerk. The app does not create columns, change schemas, edit task bodies, alter sharing or reconcile memberships.

The latest verified card action in this session can be undone with **Cmd-Z / Edit → Undo Move Card** and redone with **Cmd-Shift-Z / Edit → Redo Move Card**. The exact prior value, including absence or a literal empty string, is retained with memo scope, collection overrides and the confirmed post-write version. Each inverse checks that version and state before writing only the same property. A pending inverse disables only its own Undo/Redo entry until verified; unrelated card operations stay interactive. Failed writes create no durable history, and a new move clears redo immediately. History is in memory and is cleared at sign-out or quit. Collection-scoped writes remain unsupported because they lack version protection.

Collection instructions and status meanings still apply. Moving to Done does not create completion evidence.

## Tests and verification status

Run the core tests on macOS:

```sh
swift test
```

The core tests cover OAuth validation, PKCE/callback binding, real loopback listener cleanup, read-tool restrictions, canonical links, selection persistence, column grouping/order, pagination, move validation/conflict/read-back behavior, exact-value undo/redo, optimistic counts, rapid moves, rollback, stale-completion isolation, recoverable Trash ownership checks, removal rollback, restore/redo and independent queued removals. Loopback tests bind `127.0.0.1:53682`; stop any active sign-in first and allow local loopback access. Tests do not perform real login or read real Keychain credentials.

The signed app builds and all 74 core tests pass locally. A universal arm64/x86_64 Release archive passes strict signature verification with Hardened Runtime enabled and the Productivity app category. The native workspace and collection selectors were inspected at full container width in the running app, including opening and dismissing both menus. Native optimistic Move to, Cmd-Z and Cmd-Shift-Z were observed on a temporary synthetic fixture and confirmed by canonical read-back. An intervening remote version change was refused by native Undo, with a concise error and authoritative refetch. The fixture was restored and recoverably archived. The quiet interface was inspected after relaunch: routine operation messages and inline Undo/Redo controls are absent. Bounded concurrency, rapid intent ordering and workspace/collection read races are covered by automated tests; not every concurrent UI scenario has been exercised manually.

Routine move, saving, undo and redo status is deliberately absent from the visible interface; the card position is the feedback. Concise errors remain visible when a write or authoritative refresh fails.

This repository contains app source and synthetic tests. Private workspace data, development screenshots, build archives, logs, credentials and local evidence are excluded. No notarized release has been published.

Trash-specific verification: the signed app build and synthetic backend trash/restore contract passed; the fixture was restored and recoverably archived afterward. The full native Trash/Undo/Redo interaction has not yet been verified manually. Earlier native move/Undo/Redo evidence does not establish the new Trash UI path.
