# Snapmaker U1 ⇄ AFC integration — session context bundle

Self-contained brief for a fresh Claude session. Read this top-to-bottom
and you have what the previous session learned.

## Repos in scope

| Repo | Branch | What it holds |
|---|---|---|
| [`lindnjoe/Sovoron_klipper`](https://github.com/lindnjoe/Sovoron_klipper) | `U1_AFC` | AFC-Klipper-Add-On fork with U1 hooks. Has `extras/AFC*.py` and `extras/AFC_U1_rfid.py`. |
| [`lindnjoe/U1_Backup`](https://github.com/lindnjoe/U1_Backup) | `main` (this doc lives on `claude/analyze-u1-state-machine-boRus`) | Snapmaker U1 firmware Klipper modules: `print_task_config.py`, `flow_calibrator.py`, `filament_feed.py`, etc. |

Repository scope is restricted to these two — anything outside is denied.

## Hardware

- **U1** = Snapmaker quad-extruder toolchanger. Each hotend has its own in-head filament feeder (`filament_feed` module) with a motion sensor `e?_filament` ~2-3 mm above the extruder gears. `tool_stn = 40 mm` from sensor → nozzle.
- **AFC** = Armored Turtle Auto Filament Changer. Each `[AFC_extruder extruderN]` block maps to one physical hotend.
- Mixed topology: some hotends are **standalone** (1 AFC lane straight into the head port, U1's in-head feeder owns the last meter) and some are **bypass / BoxTurtle** (4 lanes feed one hotend; U1's in-head feeder is mechanically removed; AFC drives lane to motion sensor, syncs, pushes `tool_stn`).

## File inventory (current state on disk)

### On Sovoron_klipper @ U1_AFC

| File | Purpose | State |
|---|---|---|
| `extras/AFC_U1_rfid.py` | Polls U1 `filament_detect` for RFID tag data, syncs to AFC lane + Spoolman | Patched: per-material density table + `_clear_lane` now clears `spool_id`. Commit `785cba4`. |
| `extras/AFC.py`, `extras/AFC_lane.py`, `extras/AFC_error.py`, `extras/AFC_extruder.py`, etc. | AFC core | Stock from Armored Turtle (with the U1_AFC fork's customizations). |

### On U1_Backup (lives on Snapmaker)

| File | Purpose | Notes |
|---|---|---|
| `print_task_config.py` | Holds per-print toolmap: `extruders_used`, `filament_type`, `filament_vendor`, `flow_calibrate`, etc. | Exposes gcodes `SET_PRINT_USED_EXTRUDERS`, `SET_PRINT_TASK_PARAMETERS`, `GET_PRINT_TASK_CONFIG`. Most have a **PRINTING-state guard** — see gotchas. |
| `flow_calibrator.py` | Pressure-advance calibration via inductance coil | `cmd_FLOW_CALIBRATE` — gates on `filament_type != 'NONE'`, filament sensor, and `is_allow_to_flow_calibrate(vendor,type,sub,nozzle)`. `FORCE=1` skips the last. |
| `filament_feed.py`, `filament_entangle_detect.py`, `filament_detect.py` (RFID) | U1's per-extruder feeder FSM + sensors | `SM_PRINT_AUTO_FEED EXTRUDER=N` is the user-facing entry point. |

### New files added to the U1's `~/printer_data/klipper/extras/` (not in git)

| File | Purpose |
|---|---|
| `auto_toolmap.py` | Parses Orca CONFIG_BLOCK tail (`; filament used [g] =`, `; filament_type =`, `; filament_vendor =`, `; filament_settings_id =`) and pushes directly into `print_task_config.print_task_config` dict in-memory. Bypasses the PRINTING-state guard. Has `[auto_toolmap] enable: True/False` config option; when `False`, forces `cfg['flow_calibrate'] = False` so `SM_PRINT_FLOW_CALIBRATE` silent-skips. Registers `PUSH_TOOLMAP_FROM_FILE` and `AUTO_TOOLMAP_SET ENABLE=0\|1`. |

### Macros in printer.cfg

- `PRINT_START` — first line is `PUSH_TOOLMAP_FROM_FILE`. Then preheat, debris detect, `SM_PRINT_CHECK_SWITCH_EXTRUDER`, staggered preheat+`SM_PRINT_AUTO_FEED`+`SM_PRINT_FLOW_CALIBRATE EXTRUDER=N FORCE=1` per tool, rough Z home, bed plate detect, deep clean, bed mesh, purge line, `SET_MAIN_STATE MAIN_STATE=PRINTING`. **No `SET_PRINT_PREFERENCES` line** — auto_toolmap owns `flow_calibrate`.
- `AFC_TOOL_LOAD_U1` — wired via `custom_load_cmd` on standalone-extruder `[AFC_extruder]` blocks. Sets action codes, pins idle timeout, calls `SM_PRINT_AUTO_FEED EXTRUDER={ext}`.
- `AFC_TOOL_UNLOAD_U1` — wired via `custom_unload_cmd`. Calls `INNER_FILAMENT_UNLOAD` (cut + clean + retract). Single-lane only — must NOT be wired into multi-lane (BoxTurtle) extruder blocks or AFC will recurse.

### `[AFC_extruder]` config pattern

- Standalone extruders (e.g. `extruder`, `extruder2`, `extruder3`): set `custom_load_cmd: AFC_TOOL_LOAD_U1` and `custom_unload_cmd: AFC_TOOL_UNLOAD_U1`.
- Bypass / BoxTurtle extruder (e.g. `extruder1`): **omit** `custom_load_cmd` and `custom_unload_cmd`. AFC's stock `TOOL_LOAD` then natively drives the lane to the U1's motion sensor, syncs the lane stepper to the hotend extruder, and pushes `tool_stn = 40 mm`. That's exactly the desired bypass behavior.

### Slicer (Orca) machine start gcode

Single line:
```
PRINT_START BED_TEMP={bed_temperature_initial_layer_single} NOZZLE_TEMP_T0={nozzle_temperature_initial_layer[0]} INITIAL_EXTRUDER={initial_extruder} TOTAL_LAYER={total_layer_count} BED_TYPE="{curr_bed_type}"
```
Anything more than this caused steps to run twice (the slicer template was duplicating PRINT_START's contents).

## Gotchas — things that bit the previous session

1. **`SDCARD_PRINT_FILE` flips `print_stats.state → 'printing'` BEFORE the file's `PRINT_START` runs.** This makes `SET_PRINT_TASK_PARAMETERS` reject (line ~992 in `print_task_config.py` raises `Cannot set print task parameters during printing`). **Fix:** auto_toolmap writes directly to `ptc.print_task_config[...]` from Python. No gcode path.

2. **`machine_state_manager.main_state` is independent of `print_stats.state`.** The U1 has its own state machine on top of Klipper's. `SET_PRINT_USED_EXTRUDERS` guards on `main_state == 'PRINTING'` (which doesn't go PRINTING until `SET_MAIN_STATE MAIN_STATE=PRINTING` at the end of PRINT_START), while `SET_PRINT_TASK_PARAMETERS` guards on `print_stats.state` (already 'printing'). The two are not aliases.

3. **Orca puts `; filament used [g] = ...` in the CONFIG_BLOCK at the END of the gcode file**, not the header. A header-only scanner finds nothing. `auto_toolmap.py` scans the last 128 KiB first, then falls back to head.

4. **`flow_calibrate` requires `filament_type != 'NONE'` for that extruder.** Pushing `extruders_used` alone is not enough — `filament_type`, ideally also `filament_vendor`, must be set. Orca's CONFIG_BLOCK has `; filament_type = "PLA";"PETG";...` and `; filament_vendor = "Bambu";"Generic";...` — auto_toolmap parses both.

5. **`is_allow_to_flow_calibrate(vendor, type, sub_type, nozzle_diameter)` further gates flow cal** against the U1's built-in filament profile table. Custom Orca filament names don't match. Workaround: pass `FORCE=1` to each `SM_PRINT_FLOW_CALIBRATE` call. Proper fix would be loading matching profiles into the U1's filament_parameters table.

6. **`AFC` doesn't emit `afc:runout` / `afc:jam` events** in this fork. AFC errors flow through `afcError.AFC_error()` → renamed `PAUSE`. An event-listener-based bridge into U1's exception_manager won't fire; the bridge would have to be a direct patch to `extras/AFC_error.py`. Decided not worth it for cosmetic UI parity.

7. **`G28 Z Z_OFFSET -0.07` uses SPACE not `=`.** The U1's G28 extension parses space-separated. `G28 Z Z_OFFSET=-0.07` fails with `unable to parse =-0.07`. `BED_MESH_CALIBRATE` is stock Klipper and uses `=`.

8. **U1's `INNER_FILAMENT_UNLOAD` handles the head-side cut + clean + retract natively.** For standalone extruders, `AFC_TOOL_UNLOAD_U1` just delegates to it. For bypass, AFC's stock unload (head-side cut handled by AFC tip-forming + bowden retract) is fine — don't override.

## Open items / decisions

- **U1 touchscreen exception bridge**: skipped. Would need direct patch to `extras/AFC_error.py` in Sovoron_klipper@U1_AFC. AFC errors still pause correctly via the renamed PAUSE flow; only the touchscreen UI loses the coded-exception card.
- **`INNER_RESUME` override for bypass replenish**: not needed. AFC `infinite_spool: True` + `runout_lane: laneN` on bypass lanes makes replenish transparent to the U1 (the motion sensor never goes empty because AFC swaps lanes upstream). Only the full-exhaustion case falls back to U1's manual-load resume, which is fine.
- **Tier-4 RFID Medium-severity fixes**: silent `except: pass` in `_on_filament_info_update`, `_poll_cb`, `_get_channel_info` (three call sites) eat all exceptions. If RFID stops working it leaves no log trace. Deferred — patch ready to apply when wanted.
- **Spoolman density table accuracy**: 30-ish materials covered with prefix matching. If a user prints an obscure material (e.g., PPSU, PEI), Spoolman length tracking will be slightly off until added.

## Where state actually lives

| What | Where | When |
|---|---|---|
| `extruders_used`, `filament_type`, `filament_vendor`, `flow_calibrate` | `print_task_config.print_task_config` dict | In-memory per print. Persisted to `~/snapmaker_config/print_task.json` on `update_snapmaker_config_file()`. auto_toolmap deliberately doesn't persist — per-print is correct. |
| Pressure advance K per extruder | `flow_calibrator._current_k` | Persisted to `~/snapmaker_config/flow_calibrator.json`. Reloaded + applied on boot. |
| `_calibrated_in_printing[name]` | flow_calibrator instance | Reset on `virtual_sdcard:reset_file`. Prevents re-cal mid-print. |
| AFC lane status, spool_id | `printer.AFC.lanes['laneN']` + `printer.AFC.spool` | In AFC's own vars file. |
| RFID UID per channel | `AFC_U1_RFID._last_uid` | RAM only; reset on Klipper restart. |

## Quick decision tree for resuming work

1. New error during `PRINT_START`? Check `klippy.log` for `[print_task_config]` or `[flow_calibrate]` lines and search this doc's "Gotchas" by message.
2. Tool change broken? Verify `[AFC_extruder extruderN]` for the affected hotend: bypass should have NO `custom_*_cmd`; standalone should point to the U1 macros.
3. RFID not detecting? Check `[auto_spoolman_create]` on the AFC unit; check `klippy.log` for `U1 RFID:` lines. If silent, the Medium-severity logging gap mentioned above is the cause.
4. Flow cal not running? In order: (a) `GET_PRINT_TASK_CONFIG` — is `flow_calibrate: True`? (b) Is `[auto_toolmap] enable: True`? (c) Is `filament_type[i]` populated for the used extruders? (d) Add `FORCE=1` to each `SM_PRINT_FLOW_CALIBRATE`.

## Useful console commands

```
GET_PRINT_TASK_CONFIG               ; show current toolmap + flow flags
PUSH_TOOLMAP_FROM_FILE              ; force re-parse from current sdcard file
AUTO_TOOLMAP_SET ENABLE=0|1         ; toggle flow cal for next print
AUTO_TOOLMAP_SET                    ; query state
FLOW_CALIBRATE TARGET=extruderN FORCE=1   ; manual run, bypass profile gate
GET_STATUS objects=AFC              ; dump AFC state (lanes, units)
```

## Commit trail (Sovoron_klipper@U1_AFC)

- `785cba4` — `AFC_U1_rfid: per-material density and clear spool_id on tag removal`
