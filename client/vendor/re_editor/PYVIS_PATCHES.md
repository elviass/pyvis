# Pyvis extensions to re_editor 0.10.0

MIT upstream source from the locked pub.dev release. Added a paragraph decorator to render diagnostic underlines and reserve space for multi-line ghost text without changing the document; added a completion refresh controller for asynchronous semantic results.

Completion fixes: debounce document changes and native input, retry lookup after paragraph layout, cancel pending requests on Esc/focus loss, update the existing lookup while preserving the selected word, expose current lookup state and bounds independently of widget disposal, and support Tab replacement of the identifier suffix. The app's completion actions defer to IME composition. Lookup bounds notify after build for parameter-hint placement.

Editor integration: default shortcut construction accepts an explicit platform override for native Mac/Windows keymaps. Swapping document controllers detaches delegate listeners from the previous document before attaching the new one, preserving independent undo histories without stale tab notifications.

Platform flags are evaluated through getters, so platform-variant tests and editor reconstruction cannot retain the first surface's mobile shortcut path.

macOS native text-input selectors now dispatch to the same editor Actions as physical shortcuts (Tab/Enter completion, movement, selection, deletion and clipboard). IME composition and read-only restrictions are retained; this fixes the formerly empty performSelector path.
