# System permissions

| Capability | Permission | MVP behavior without it |
|---|---|---|
| Read/write clipboard | none | core capture and copy work |
| Global Carbon hotkey | none | `⌘⇧V` works unless another app owns it |
| Source application name | none | frontmost process metadata works |
| Window title/context | Accessibility | not captured in MVP |
| Protected item reveal | device-owner authentication | content remains hidden |

AI Clipboard does not request Accessibility permission. It copies the selected result and leaves insertion to the user's standard `⌘V`. The app does not silently request unrelated permissions.
