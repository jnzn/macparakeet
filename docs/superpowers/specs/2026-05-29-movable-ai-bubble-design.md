# Movable AI Bubble + Tail Removal — Design

> Status: **APPROVED** (2026-05-29). Implementation pending.
> Related: Feature Inventory F3 (AI Assistant); promoted from the "Movable AI popup" backlog item.

## Context

The AI Assistant bubble (`Sources/MacParakeet/AIAssistant/`) is a non-activating,
borderless `NSPanel` (`styleMask = [.nonactivatingPanel, .borderless, .resizable]`,
`canBecomeKey == true` so its text field accepts input). It opens **anchored to the
user's text selection** and is drawn as a **speech bubble with a directional tail**
(`TailEdge` down/up/left/right) pointing at that selection.

Two problems:
1. The bubble can cover the very text you're working with, and there is no way to move it.
2. The tail is unwanted — "a silly design choice."

## Decisions

1. **Remove the tail entirely.** The bubble becomes a plain rounded-rect panel for
   *all* uses (not only when dragged). Positioning simplifies to "appear near the
   selection" rather than aiming a tail at it.
2. **Drag handle — hover-reveal.** A small two-parallel-lines grabber, bottom-center,
   hidden by default; fades in when the pointer nears the bottom edge.
3. **Cursor + hover via AppKit.** SwiftUI `.onHover` / `.cursor(...)` /
   `NSViewRepresentable` with `.activeInActiveApp` do **not** fire on a
   `.nonactivatingPanel` (CLAUDE.md known pitfall). An `NSTrackingArea` with
   `.activeAlways` drives both the handle fade-in and the cursor swap
   (`NSCursor.openHand` → `.closedHand` while dragging).
4. **Drag = native window drag.** Mouse-down on the handle calls
   `window.performDrag(with:)`, so the panel follows the pointer from wherever it
   opened.
5. **Position memory: per-conversation only.** A dragged bubble stays put for that
   session; the next open re-anchors near the new selection (today's behavior). No
   cross-launch persistence, no new UserDefaults, no Settings toggle.

## Components / boundaries

- **`AIAssistantBubbleView.swift`** — shape: remove the tail path + `tailLength` body
  insets → plain rounded rect; add the hover-revealed grabber affordance (visual only).
- **`AIAssistantBubbleController.swift`** — positioning: drop tail-edge aiming, position
  the panel near the selection; host the `NSTrackingArea` (cursor + handle visibility)
  and the `performDrag` mouse-down on the handle's hit region.
- Possibly a small **`NSView` subclass** to own the tracking area and forward the drag,
  since the SwiftUI layer can't on a non-activating panel.

## Out of scope

- Cross-launch position persistence; any Settings toggle.
- Changing the selection-anchored *open* position (it still appears near the selection).
- Any meeting auto-start/stop or unrelated AI-bubble behavior.

## Testing

View-layer AppKit/SwiftUI. Per `spec/09-testing.md` ("skip SwiftUI view tests; test
ViewModels/logic"), primary verification is **build + run the app and drag the bubble**.
Any extractable pure logic (handle hit-region math, near-selection open-position math)
gets a unit test.

### Manual verification checklist
1. Trigger the AI bubble (Option+A) on a text selection → opens near the selection,
   **no tail**, plain rounded rect.
2. Move the pointer to the bottom edge → grabber fades in; cursor becomes an open hand
   over it.
3. Click-drag the grabber → bubble follows the pointer; cursor is a closed hand while
   dragging.
4. Release → bubble stays; the text field still accepts input (can still type / ask).
5. Dismiss and reopen on a new selection → re-anchors near the new selection (the
   previous manual position is not remembered).
