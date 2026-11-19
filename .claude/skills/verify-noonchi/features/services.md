# Services on and off

Settings > Services lists each service with its path and a switch. Turning one off stops polling it and removes it from the panel and menu bar, and the panel shrinks to fit, staying directly under the menu bar.

## Sub-features

- `svc-off` removes a service from the panel and stops its reads.
- `svc-on` brings it back with a fresh read.
- `svc-resize` keeps the panel fitted to its content, with no blank band. Regression: the window used to keep its old height.
- `svc-chips` shows menu bar choices per service in custom mode.
- `svc-groups` hides an Antigravity quota group from the panel and the menu bar.

## How to get to it (user POV)

- Panel > ⋯ > Settings… > Services, then the switch next to the service.
- Panel > ⋯ > Settings… > Services, then a chip in Antigravity's "Panel groups" row.

## Driving it with control-noonchi

Preconditions: `$C start` has returned.

- **Before.** Run `$C open-panel`, `$C gap`, `$C shot before`. Note the height with all three services.
- **Turn off.** Run `$C open-settings Services`, then `$C send toggle Codex`. `$C settings` shows `disabledProviders = ['codex']`.
- **Reopen.** Run `$C close-settings`, `$C open-panel`, `$C gap`, `$C region off`, `$C shot off`. Height is smaller than before, and the gap is 2. In `off-region.png` the panel sits directly under the menu bar, with no blank band above or below it. `off-tree.json` has no `Codex`.
- **Turn on.** Run `$C close-panel`, `$C open-settings Services`, `$C send toggle Codex`, `$C wait-idle`, `$C close-settings`, `$C open-panel`, `$C gap`, `$C close-panel`. Height is back to the first one.
- **Hide a group.** Run `$C open-settings Services`, `$C send press "Claude·GPT"`, `$C settings`. It shows `panel.hiddenGroups = {'antigravity': ['Claude·GPT']}`. Run `$C close-settings`, `$C open-panel`, `$C shot groups`. Antigravity shows `Gemini 5h`, `Gemini`, and `Argon`, with no `Claude·GPT` row. With the default fake (3p5h=30 above gemini5h=12) the menu bar's Antigravity number reads 12. Press the chip again to bring the rows back.

## Gotchas

- `gap` measures the window. When the bug is present the window is too tall and the gap still reads 2, so compare heights and read the image.
- Exact heights change with the rows; what matters is that off is smaller than on.
- The fake's paths appear in the Services tab, so don't reuse these captures in public docs.
- In custom mode the menu bar item chips also have a `Claude·GPT` (its weekly window), and `press` takes the first match. Run `svc-groups` in automatic mode.
- The panel closes when a service is turned off or on while it's open, or when that service's item changes in the menu bar. That's current behavior, cause unknown. Follow the order above, and reopen before reading.
