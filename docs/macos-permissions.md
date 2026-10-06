# macOS permissions

Chat needs no screen or input permissions. Computer control uses the following
macOS permissions, with dry-run enabled by default:

- **Accessibility:** reads native and Chrome accessibility trees, presses
  controls, fills fields, and posts mouse/keyboard events. Chromium's
  `AXManualAccessibility` attribute is enabled during observation.
- **Screen Recording:** captures a downscaled JPEG with ScreenCaptureKit when
  the model asks for a picture or accessibility has no actionable elements.
  LocalPilot's overlay windows are excluded. Images go to the selected model
  server as image content and are not written to the event log.
- **Automation → Google Chrome:** opens, navigates, switches, and closes Chrome
  tabs through its scripting dictionary. The app includes the Apple Events
  entitlement and usage description. macOS may prompt on first use. If denied,
  the executor reports the failure; Chrome's ordinary accessibility and keyboard
  controls remain an alternative. Page JavaScript execution is not required.

The Permissions screen shows Accessibility and Screen Recording status and links
to System Settings. Automation can be managed in System Settings → Privacy &
Security → Automation after the first request.

Agent Mode appears for computer work, with Pause/Continue/Stop and inline policy
approvals. The global stop shortcut (⌥⌘.) needs no extra permission. Dry-run
validates actions without clicking, typing, opening tabs/apps, accessing the
clipboard, or running terminal commands. Observations may still read the screen.
