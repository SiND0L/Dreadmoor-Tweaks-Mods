# DreadmoorTweaks

A UE4SS Lua mod for **Dreadmoor** (UE 5.6) built from the game's `DUMP-MODDING`
dump. Its main feature is a runtime third-person camera; it also adds a few
camera controls and debug helpers exposed by the game's own classes.

## Install

Everything lives under the game's UE4SS folder:

```
Dreadmoor\Binaries\Win64\ue4ss\
    Mods\
        DreadmoorTweaks\
            enabled.txt
            Scripts\
                main.lua
        mods.txt          <- add:  DreadmoorTweaks : 1
```

`mods.txt` must contain the entry **before** the built-in keybinds comment:

```
DreadmoorTweaks : 1

; Built-in keybinds, do not move up!
Keybinds : 1
```

The mod is written as a single `main.lua` on purpose so it has no local
`require` dependency. All tunables are in the `CONFIG` table at the top of the
file.

Third person is **off by default** on purpose: press `F2` once in game. Set
`startEnabled = true` in `CONFIG` to have it engage automatically.

## Keys

| Key | Action |
| --- | --- |
| `F1` | Print help and status to the UE4SS log |
| `F2` | Toggle third person |
| `F4` | Cycle shoulder preset (right / left / center) |
| `Page Up` / `Page Down` | Camera distance |
| `+` / `-` (`OEM_PLUS` / `OEM_MINUS`) | Camera field of view |
| `Home` | Reset distance, FOV and shoulder |
| `End` | Toggle camera collision |
| `F6` | Cycle movement speed (x1 / x1.5 / x2 / x3) |
| `F7` | Toggle god mode |
| `F8` | Toggle infinite stamina / oxygen |
| `F10` | Toggle infinite ship fuel |
| `F11` | Open the game's built-in cheat panel |
| `Insert` | Teleport to ship |
| `Delete` | Cycle slow motion (1.0 / 0.5 / 0.25) |
| `Num 1` | Toggle the character flashlight |
| `Num 2` | Cycle time of day (dawn / noon / dusk / midnight) |
| `Num 3` | Cycle ship speed multiplier (x1 / x1.5 / x2 / x3) |
| `Num 4` | Cycle graphics quality preset (low / medium / high / epic) |

`F3` is intentionally unused because `LineTraceMod` already binds it, and
`F5` / `F9` / `F12` are avoided because they commonly conflict with
quicksave / quickload / Steam screenshot.

## Console command

The mod registers `dmt`. Open the UE4SS console (`Ctrl+O` by default) and use:

```
dmt help                 Show the command list
dmt status               Print camera and cheat state
dmt tp                   Toggle third person
dmt hud                  Toggle the game HUD
dmt cheat                Open the game's cheat panel
dmt qsave / dmt qload    Quick save / quick load
dmt god                  Toggle god mode
dmt vitals               Toggle infinite stamina and oxygen
dmt fuel                 Toggle infinite ship fuel
dmt speed                Cycle movement speed
dmt shipspeed            Cycle ship speed multiplier
dmt repair               Restore ship health
dmt flashlight           Toggle the character flashlight
dmt time [0-24]          Set the time of day (or cycle without a value)
dmt quality [0-3]        Set the graphics quality preset (or cycle)
dmt slowmo               Cycle time dilation
dmt teleport             Teleport to ship
dmt shoulder             Cycle shoulder preset
dmt collision            Toggle camera collision
dmt dist <units>         Set camera distance (100-800)
dmt fov <degrees>        Set field of view (55-120)
dmt reset                Reset camera settings
```

## How it works

* A `USpringArmComponent` and a `UCameraComponent` are created at runtime on
  the possessed `ACharacter`. The camera is attached to the spring arm's
  `SpringEndpoint` socket and the arm uses `bUsePawnControlRotation`, so the
  engine drives all camera smoothing and collision.
* The Blueprint first-person camera (`BP_PlayerCharacter_C.Camera`) is
  deactivated while third person is active, and its active state is restored
  when third person is turned off or suspended.
* `bFindCameraComponentWhenViewTarget` is forced on so the pawn's
  `CalcCamera` selects the new camera component.
* The pawn's primitive components get `bOwnerNoSee = false` and
  `FirstPersonPrimitiveType = None` so the full body renders; the original
  values are restored afterwards.
* First-person viewmodel components parented under the Blueprint camera are
  hidden while third person is active (`hideCameraAttachments`).
* Third person is suspended automatically while `bIsDead` or
  `bDialogueSequenceCameraActive` is set, and optionally while `IsAiming`
  (`suspendWhileAiming`). The rig is torn down and rebuilt cleanly.
* Only `ACharacter` pawns are rigged. The ship pawn (`ADrdShipBase`) is skipped.

## Notes on the cheat features

* **God mode** calls the game's own
  `UDrdBlueprintFunctionsDebug.SetCheatInvulnerable(true/false)` through its
  class default object, then also refills `UDrdAttributeSetHealth.Health` to
  `MaxHealth` and clears `Radiation` every update as a fallback.
* **Infinite vitals** refills `UDrdAttributeSetPlayerCharacter.Stamina` to
  `StaminaMax`, and the diver's oxygen set to `MaxOxygen` when one exists.
* **Ship fuel** refills `UDrdAttributeSetShip.Fuel` to `FuelMax` on the
  `BP_SmallBoat_V2_C` instance.
* **Speed** scales `MaxWalkSpeed`, `MaxWalkSpeedCrouched`, `MaxSwimSpeed` and
  `MaxFlySpeed`, plus the `WalkSpeed` / `RunSpeed` attributes. Any value the
  game writes (for example when sprinting) is adopted as a new baseline and
  scaled instead of being overwritten, so sprint still works.
* **Ship speed** scales `AttributeSetShip.MaxSpeed`, `MaxBackwardSpeed`,
  `AccelerationAtMinSpeed`, `AccelerationAtMaxSpeed`, `MaxAngularSpeed` and
  `AngularAcceleration`.
* **Ship repair** calls `BP_SmallBoat_V2_C:RestoreHealthOnRevive()` and
  `HealAllCosmeticHullElements`.
* **Flashlight** first tries the game's `IA_CharLight` event, then falls back
  to toggling `BP_PlayerCharacter_C.SpotLight` and `bFlashlightIsOn` directly.
* **Time of day** calls `Ultra_Dynamic_Sky_C:Transition Time of Day` (dawn,
  noon, dusk, midnight presets) with a short transition.
* **Quality** applies the standard `sg.*Quality` scalability console variables.
* **Cheat panel** reads `CheatPanelClass` through UE4SS's soft-pointer
  accessors (`GetAssetPathName`), loads it with `LoadClassAsset_Blocking`, and
  creates it with `WidgetBlueprintLibrary.Create`. When the property is empty
  in the retail build, the mod searches the Asset Registry for
  `WBP_CheatPanel`, rebuilds its generated-class path, and loads that instead.
  If all of that fails, it calls the game's Blueprint Enhanced Input event.
* **Quick save / quick load** call the game's own Blueprint Enhanced Input
  events on `BP_DrdPlayerController_C`.
* **Teleport** moves the pawn to the ship's `TeleportToOnUnpossess` component,
  then falls back to the game's dev teleport event.

## Tuning

Open `Scripts/main.lua` and edit `CONFIG`:

```lua
startEnabled = false        -- true to enable third person at launch
armLength = 320.0           -- default boom length
targetOffsetZ = 55.0
fieldOfView = 90.0
collisionProbeSize = 12.0
bodyFollowsCamera = true    -- character yaw follows the camera
suspendWhileAiming = false
hideCameraAttachments = true
```

`shoulderPresets` is a list of `{ label, Y, Z }` entries used by `F4`.

## Troubleshooting

UE4SS writes its log to:

```
Dreadmoor\Binaries\Win64\ue4ss\UE4SS.log
```

Look for lines starting with `[DreadmoorTweaks]`. If third person does not
engage, check for:

* `Third-person rig created on ...` — the rig was built.
* `Failed to add spring arm component` / `Failed to add camera component` —
  component creation failed.
* `Could not resolve SpringArmComponent / CameraComponent classes` — the
  `StaticFindObject` paths did not resolve.

Useful console commands for diagnosis:

```
dmt status
```

If the camera stays first-person, the pawn's view target may not be the pawn
itself. In that case the game is overriding the view target somewhere and the
rig needs a different hook; report the `UE4SS.log` lines and the context.

For `F11`, the log prints `CheatPanelClass lua=... path=...`. If the path is
`nil`, the next two lines show `PausePanelClass` and `MapPanelClass`:

* Both also `nil` — the soft-pointer read failed; report the log.
* They have paths — the retail build has no cheat panel asset assigned, so the
  mod first tries the cooked package path
  `/Game/Dreadmoor/UI/Debug/WBP_CheatPanel.WBP_CheatPanel_C`, then looks for an
  already-loaded `WBP_CheatPanel_C`, then searches the Asset Registry for
  `WBP_CheatPanel` and loads the class from the discovered path. The log shows
  `Cheat panel asset found: ...` and one of the `Cheat panel class loaded ...`
  lines. The first registry scan can cause a short hitch while it walks the
  asset list. If the lookup fails, the mod falls back to the game's
  `IA_Dev_CheatPanel` Blueprint event.

## Uninstall

Remove `DreadmoorTweaks : 1` from `mods.txt` (or set it to `0`), or delete the
`DreadmoorTweaks` folder.

## GitHub 
https://github.com/SiND0L/Dreadmoor-Tweaks-Mods/
