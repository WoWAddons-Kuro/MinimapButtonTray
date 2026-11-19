# MinimapButtonTray — spec

One button next to the minimap that holds the minimap buttons of every other addon; click it and they
open in a grid. **Classic Era (11509) and WoW Forever (16001) first**, other flavours via TOC lines.

Status: **approved, ready to build.** Owner: Kuro. License: MIT.

## Motivation

Two goals: a **bug-free** button collector, and one that **works on every WoW client version** from a
single codebase. None of the existing addons we could find achieve either — each is tied to one client
(Forever *or* Classic Era), each has its own bugs (buttons that fade out inside the tray, buttons that
escape back to the minimap, crashes with map-pin addons), and none is open-licensed, so they cannot be
fixed or extended. MinimapButtonTray is written from scratch under MIT with a client abstraction so the
same code runs, and is tested, on every flavour.

Key constraints learned the hard way on these clients:

- **Never call `Minimap:GetChildren()` on Forever.** With map-pin addons the minimap has hundreds of
  children and the client dies on an assertion (not a Lua error, not catchable). Candidates are found
  by scanning `_G` for names containing `Minimap` / `LibDBIcon10_` whose parent is a minimap frame.
- **Forever may hand addons secret values** that raise on any comparison; every number read from the
  client (size, scale, points) must be guarded.
- **Addons re-anchor their buttons constantly** (login, zone change, some every frame), so a collected
  frame's positioning methods must be neutralised while held, and fully restored on release.
- **Show/Hide must be hooked on the frame**, not via OnShow/OnHide scripts, which also fire when the
  tray itself toggles.

## Decisions

| # | Decision |
|---|---|
| Name | Folder/TOC/Title `MinimapButtonTray`. Globals: `MinimapButtonTrayDB`, frames `MinimapButtonTray_Main`, `MinimapButtonTray_Tray`, `MinimapButtonTray_Options`; namespace table `MBT` (`_G.MinimapButtonTray = MBT`). Slash `/mbt`, `/minimapbuttontray`. Chat prefix `|cff66ccffMinimapButtonTray|r`. |
| Structure | GotJunk style: flat repo, `.pkgmeta`, `.gitignore`, `README.md`, `CHANGELOG.md`, `LICENSE` (MIT), `SPEC.md`; **no bundled libs** (a collector only *reads* LibDBIcon if some other addon loaded it). Several Lua files, one `MBT` namespace via `local ADDON, MBT = ...`. |
| TOC | `## Interface: 16001` + `## Interface-Camelot: 16001` + `## Interface-Classic: 11509` (CurseForge per-flavour headers, GotJunk pattern). Other flavours added only once tested. |
| Client abstraction | `Client.lua` builds **one** `MBT.Client` table at load: `flavour` (`"era"`/`"forever"`/`"mainline"`/`"other"`), capability flags and shims (below). Every file reads APIs through `MBT.Client`, never `_G` directly, where the two clients differ. `/mbt debug` prints the table. |
| Enumeration | `_G` name scan on **all** flavours (the Era-safe `GetChildren()` buys nothing: unnamed frames fail the name rules anyway). One code path, one set of bugs. |
| Fade fix | Collected buttons never fade: lock `SetAlpha` (no-op while held), force alpha 1 via the original method, stop any `AnimationGroup` on the frame whose animations target alpha (LibDBIcon `showOnMouseover` uses `button.fadeOut`), hook its `OnPlay` to `Stop()` while collected. Re-assert alpha 1 in layout refresh. Restore recorded alpha on release. |
| Auto-hide | `db.autoHideSeconds` (default 15, 0–60, 0 = never). **Idle** timer: reset while mouse is over the main button or the tray; counted in the tray's `OnUpdate` poller (same one that drives mouse-leave close). |
| Mouse-leave close | Kept as a separate option `db.closeOnLeave` (default false, 0.8 s grace), polled, not OnLeave-driven (a collected button's OnLeave is not ours). |
| Options UI | Blizzard Settings panel: `Settings.RegisterCanvasLayoutCategory` when `Client.hasSettingsAPI`, else `InterfaceOptions_AddCategory`. Sections: *Layout*, *Behaviour*, *Buttons* (tick list: collected / ignored). Right-click on the main button and `/mbt` open it. |
| DB | Account-wide `MinimapButtonTrayDB`, validated key by key against defaults at login (bad/old values fall back individually). No per-character data. |

## Client abstraction (`Client.lua`)

```lua
MBT.Client = {
  flavour          = "era" | "forever" | "mainline" | "other",  -- WOW_PROJECT_ID + interface number
  interface        = 11509 | 16001 | ...,                        -- select(4, GetBuildInfo())
  IsSecret         = issecretvalue or function() return false end, -- Forever: opaque values raise on compare
  GetAddOnMetadata = C_AddOns.GetAddOnMetadata or GetAddOnMetadata,
  GetMouseFoci     = GetMouseFoci or function() return { GetMouseFocus() } end,
  hasCompartment   = AddonCompartmentFrame ~= nil,   -- Forever yes, Era no
  hasEditMode      = EditModeManagerFrame ~= nil,    -- Forever yes, Era no (minimap can still move via addons)
  hasFixedStrata   = type(UIParent.SetFixedFrameStrata) == "function",
  hasSettingsAPI   = Settings and Settings.RegisterCanvasLayoutCategory ~= nil,
  minimapParents   = { "Minimap", "MinimapBackdrop", "MinimapCluster" },  -- frames whose named children are candidates
  backdropTemplate = BackdropTemplateMixin and "BackdropTemplate" or nil,
}
```

Rules: a missing capability is a **flag**, not an error; code branches on flags, never on `flavour`
except for the debug print. `MBT.Client.ReadNumber(v)` → `v` when a plain readable number, else `nil`
(secret-value guard); every width/height/scale/point read from the client goes through it.

## Collection rules (`Collector.lua`)

Sources, in order each scan: (1) `LibDBIcon-1.0:GetButtonList()` → `GetMinimapButton(name)`;
(2) `LibMapButton-1.1.buttons`; (3) `db.include` paths (`Frame` or `Frame.child.child`); (4) `_G` name scan.

A frame from the **name scan** is taken when all of:

| rule | detail |
|---|---|
| is a Frame | `IsObjectType("Frame")`, not forbidden, not protected (`IsProtected()` — cannot move in combat) |
| not ours, not collected, not in `db.ignore` | — |
| not Blizzard | `issecurevariable(_G, name)` |
| parent is a minimap frame | parent ∈ `Client.minimapParents` |
| name matches a button pattern | `^LibDBIcon10_`, `MinimapButton`, `MinimapBtn`, `MinimapIcon`, `MinimapFrame`, `[-_]Minimap[-_]`, `Minimap$` (case-insensitive) |
| not a pin | prefixes `HandyNotes`, `TomTom`, `HereBeDragons`, `Questie`, `GatherMate`, `Routes`, `EasyFind`, `Pin`; or name ends in a digit — **except** `^TomCats-` and `^LibDBIcon10_` |
| not an overlay | width and height ≤ 80 (when readable) |

Library and include sources skip the name/size rules (the player or the library vouched for it).

### Take / give back

`Grab(frame)` records: parent, every anchor point, scale, alpha, strata, level, fixed-strata/level
flags, `OnDragStart/OnDragStop`, the frame's own `SetPoint/ClearAllPoints/SetParent/SetScale/SetAllPoints/SetAlpha`
(rawget). Then: reparent into the tray via the *original* `UIParent.SetParent`, clear points, restack
above the tray (unpin fixed strata/level first, repin after), `SetIgnoreParentScale(false)`, scale =
`db.buttonScale`, alpha = 1, nil the drag scripts, install no-ops for the locked methods, stop/guard fade
animation groups, `hooksecurefunc` `Show/Hide/SetShown` (once per frame, ever) to relayout when the
addon hides its own button. `Release(frame)` undoes every step from the record.

A frame whose `Grab` raises is marked failed and never retried (listed by `/mbt debug` with the error).

### When to scan

`PLAYER_LOGIN` (then +0 s, +2 s, +8 s), `ADDON_LOADED` after login (coalesced, +0.5 s), `PLAYER_ENTERING_WORLD`
(+1 s), `LibDBIcon_IconCreated` callback, `PLAYER_REGEN_ENABLED` if a scan was deferred by combat, tray
open (name scan throttled to once per 5 s), `/mbt rescan`. Combat: scans are deferred, never run.

## Layout (`Tray.lua`)

- Main button: 30×30, texture `Media/MinimapButtonTray.tga` (highlight on hover), draggable, clamped,
  position stored as offset of its centre from the minimap centre in UIParent units (follows Edit Mode /
  addon minimap moves, survives rescale). Right-click → options. Tooltip: count, click hints.
- Tray: child of main, strata HIGH, `EnableMouse(false)` (never steals clicks; hover is polled), grid of
  visible collected buttons, `db.perRow` (1–12), `db.direction` ∈ 8 directions (`leftdown` …), cell = max
  visible button size (capped 64). Empty label when nothing is collected.
- Poller (`OnUpdate`, 0.1 s tick, only while the tray is shown): mouse-leave close and auto-hide idle.
- Compartment: `db.hideCompartment` hides `AddonCompartmentFrame` (hook OnShow) when `Client.hasCompartment`.

## Settings

| key | default | meaning |
|---|---|---|
| `direction` | `leftdown` | grow direction, 8 values |
| `perRow` | 5 | 1–12 |
| `scale` | 1 | main button + tray, 0.5–2 |
| `buttonScale` | 1 | collected buttons, 0.5–2 |
| `autoHideSeconds` | 15 | idle seconds before the tray closes itself; 0 = never; slider 0–60 step 1 |
| `closeOnLeave` | false | close 0.8 s after the mouse leaves main+tray |
| `hideCompartment` | false | only shown when the client has one |
| `posX`, `posY` | nil | main button offset from minimap centre; nil = default (bottom-left of the ring) |
| `ignore` | `{}` | `[frameName] = true` never collected |
| `include` | `{}` | `[path] = true` always collected |

## Slash `/mbt`

`(none)`/`options` · `toggle` · `show` · `hide` · `list` · `ignore <name>` · `unignore <name>` · `add <path>` ·
`remove <path>` · `reset` (position) · `rescan` · `status` · `debug` (client table, every candidate and why it
was skipped, last grab error) · `help`.

## Files

```
MinimapButtonTray/
  MinimapButtonTray.toc  Client.lua  Core.lua  Collector.lua  Tray.lua  Options.lua
  Media/MinimapButtonTray.tga  Assets/MinimapButtonTray_AppIcon.{png,jpg}
  README.md  CHANGELOG.md  LICENSE  SPEC.md  .pkgmeta  .gitignore
```

Load order: `Client` → `Core` (namespace, DB, events, slash) → `Collector` → `Tray` → `Options`.
Every file declares its `local` state at the top, above all functions (GotJunk lesson).

## Plan

- [ ] Owner answers Open questions; spec updated
- [ ] Scaffold repo (`git init`, TOC, .pkgmeta, .gitignore, LICENSE MIT, README, CHANGELOG), delete `MinimapButtonTray.Kuro/`, `PROJECT_STRUCTURE.md` entry
- [ ] `Client.lua` + `/mbt debug` client dump
- [ ] `Core.lua`: DB defaults/validation, events, scan scheduling, slash
- [ ] `Collector.lua`: sources, rules, Grab/Release incl. fade lock, hooks, describe
- [ ] `Tray.lua`: main button, tray grid, position, poller (close-on-leave + auto-hide), compartment
- [ ] `Options.lua`
- [ ] In-game: Era — collect LibDBIcon + named buttons, fade stays off, auto-hide, release on untick
- [ ] In-game: Forever — same, plus no crash with pin addons, compartment hide, Edit Mode minimap move
- [ ] README/CHANGELOG final, owner sign-off, release via `cmd\release.cmd`

## Open questions

None open. Answered 2026-11-18 (owner):

1. Name `MinimapButtonTray`, slash **`/mbt`** (short, for debugging) + `/minimapbuttontray`.
2. Auto-hide: idle timer, **0–60 s, 0 = never, default 15 s**.
3. Options: **Blizzard Settings panel** with clean sections, same style as GotJunk.
4. Fade fix as specced; easy to test — more than half the owner's minimap buttons fade together.
5. TOC: CurseForge-style `## Interface-<Flavour>:` headers, **Era + Forever only** to start.
6. Account-wide DB only.
7. `MinimapButtonTray.Kuro/` already deleted.
8. Main button uses the **app icon** `Assets/MinimapButtonTray_AppIcon.png` (a 3×3 grid of buttons in a
   stone frame). `Scripts/MakeAddonIcon.cs` makes `Media/MinimapButtonTray.tga`, used for the main
   button texture and the TOC `IconTexture`.

## After v1

- **Pinned list** (v2): a second drop zone below the grid. Dragging a collected button onto it pins it
  as a labelled row — `[button] [addon name]`, one per line — so the handful of buttons used daily are
  found at a glance instead of in a pile of 40 icons. Stored in `db.pinned` (ordered array of names).