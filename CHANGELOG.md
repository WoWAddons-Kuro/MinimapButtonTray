# Changelog

## Unreleased

First version. Classic Era and WoW Forever from one codebase.

- One button next to the minimap; left-click opens a grid of every collected addon button, right-click opens options, drag moves it. The button follows the minimap when that is moved.
- Collects LibDBIcon buttons and named addon buttons on the minimap. Blizzard frames, map pins and protected frames are skipped. Map-pin-heavy setups are safe: the minimap's children are never enumerated.
- Collected buttons never fade while in the tray: their alpha is locked and their fade animations are stopped. Restored on release.
- Tray auto-hides after an idle time (default 15 s, 0 = never) and, optionally, shortly after the mouse leaves it.
- Eight grow directions, buttons per row, tray scale and button scale.
- Options in the Blizzard Settings panel with a tick list of collected buttons; untick to put one back on the minimap.
- `/mbt` with list / ignore / unignore / add / remove / reset / rescan / status / debug.
- `Client.lua` abstraction: flavour detection and capability flags, so one code path serves every client.
