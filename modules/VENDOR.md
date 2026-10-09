# Vendored modules

Third-party HDL cores copied into the tree -- no submodules, so the build is
self-contained and reproducible. Each keeps its own LICENSE alongside.

| module | upstream | via | licence |
|---|---|---|---|
| cpu-fx68k | fx68k by Jorge Cwik | the Master of Weapon core (originally Xenophobe) | GPL-3.0 (`modules/cpu-fx68k/LICENSE`) |
| cpu-tv80 | https://github.com/hoglet67/tv80 (Guy Hutchison's tv80) | the Master of Weapon core, with its `tv80s_cen.v` clock-enable wrapper | MIT |
| sound-jt51 | https://github.com/jotego/jt51 `hdl/` | the Xenophobe core | GPL-3.0 |
| `target/pocket/analogizer/` | RndMnkIII's Analogizer adapter module (`openFPGA_Pocket_Analogizer` 1.4) and the 14 files it instantiates, verbatim; `analogizer.qip` is ours | https://github.com/RndMnkIII/MiraxPocket `src/fpga/analogizer/` at 9dfdd2b9bec79fe5ea10e154a0613a0c9d4fe37f, via the pocket-core-template | GPL-3.0-or-later; `hq2x.sv`, `scandoubler_2.v`, `yc_out_legacy.sv` carry their own GPL headers |

Written here rather than vendored, from MAME's device models: the TC0100SCN
and PC090OJ line renderers, the TC0110PCR palette, the TC0220IOC and the
PC060HA. See `docs/hardware.md` for the behaviour they were written against
and `tools/render_model.py` for the video semantics, which is checked against
MAME on every state in `ref/states`.

The Analogizer module lives under `target/pocket/` rather than `modules/`
because it is the Pocket's cartridge port, not the machine, and so that the
per-module lint does not sweep it in: `core.qip` includes its own
`analogizer.qip`, and `sim/lint.sh` lints it behind
`target/pocket/pocket_analogizer.sv` with a stand-in for its one VHDL file
(`sim/ps2_keyboard_stub.v`).  Left out, as nothing instantiates them:
`scandoubler.v`, `scanlines.v`, `yc_out.sv`, `psPAD_top.v`, `psx_control.v`,
`csync.v`, `sync_fix.v` (also defined inside the top file),
`two_button_press_detector.v`, `uart_tx.v` and `sine_lut.mem`.

To update one: re-copy from upstream at the new commit and record it here.
