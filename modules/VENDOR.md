# Vendored modules

Third-party HDL cores copied into the tree -- no submodules, so the build is
self-contained and reproducible. Each keeps its own LICENSE alongside.

| module | upstream | via | licence |
|---|---|---|---|
| cpu-fx68k | fx68k by Jorge Cwik | the Master of Weapon core (originally Xenophobe) | GPL-3.0 (`modules/cpu-fx68k/LICENSE`) |
| cpu-tv80 | https://github.com/hoglet67/tv80 (Guy Hutchison's tv80) | the Master of Weapon core, with its `tv80s_cen.v` clock-enable wrapper | MIT |
| sound-jt51 | https://github.com/jotego/jt51 `hdl/` | the Xenophobe core | GPL-3.0 |

Written here rather than vendored, from MAME's device models: the TC0100SCN
and PC090OJ line renderers, the TC0110PCR palette, the TC0220IOC and the
PC060HA. See `docs/hardware.md` for the behaviour they were written against
and `tools/render_model.py` for the video semantics, which is checked against
MAME on every state in `ref/states`.

To update one: re-copy from upstream at the new commit and record it here.
