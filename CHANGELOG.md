# Changelog

## Unreleased

First version. Classic Era and WoW Forever from one codebase.

- One button next to the minimap; left-click opens a grid of every collected addon button, right-click opens options, drag moves it. The button follows the minimap when that is moved.
- Collects LibDBIcon buttons and named addon buttons on the minimap. Blizzard frames, map pins and protected frames are skipped. Map-pin-heavy setups are safe: the minimap's children are never enumerated.
- Collected buttons never fade while in the tray: their alpha is locked and their fade animations are stopped. Restored on release.
- Tray auto-hides after an idle time (default 5 s, 0 = never, 0.25 s steps up to 15 s).
- Eight grow directions, buttons per row, tray scale and button scale.
- **Shift-drag** a button in the tray to reorder the grid. Drop it on the zone under the grid to **pin** it: pinned buttons are listed one per row as `[button] [addon name]`, so the few you use daily are found at a glance. Drag a pinned button back onto the grid to unpin. Order and pins are saved.
- Options in the Blizzard Settings panel with a tick list of collected buttons; untick to put one back on the minimap.
- `/mbt` with list / ignore / unignore / add / remove / reset / rescan / status / debug.
- `Client.lua` abstraction: flavour detection and capability flags, so one code path serves every client.
