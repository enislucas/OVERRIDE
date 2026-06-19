# v4 design gallery — pick your look

Every PNG here is a pixel-accurate, implementable mockup of the actual quiz screen
(not a random dribbble screenshot). Sources in `src/` — open any .html in a browser
to see animated versions.

## Themes (full quiz screen restyled)
| file | idea |
|---|---|
| `theme_A_phosphor_green.png` | v3's identity, polished: deeper glow, bigger type |
| `theme_B_amber_terminal.png` | warm amber phosphor — 1970s terminal |
| `theme_C_red_alert.png` | red/black emergency, hazard stripes, pulsing clock |
| `theme_D_cyberpunk_neon.png` | cyan/magenta chromatic split, angular cuts, neon grid |
| `theme_E_ghost_minimal.png` | near-monochrome stealth, hairline rules, one green accent |
| `theme_F_crt_deep.png` | full CRT monitor simulation: curvature, scanlines, RGB fringe, flicker |

## Effects (small tweaks, mix & match)
| file | idea | CPU |
|---|---|---|
| `effect_01_matrix_rain.png` | falling glyph columns behind the panel | ~1–2% while ringing |
| `effect_02_glitch_rgbsplit.png` | red/cyan tear on wrong answers + key moments | 0 idle (burst only) |
| `effect_03_cjk_vanish.png` | the v2 "chinese vanish" — also on quiz SOLVED | 0 idle (burst only) |
| `effect_04_decrypt_reveal.png` | questions type themselves out of cipher noise (in v3 already) | 0 idle |
| `effect_05_crt_overlay.png` | scanlines + fringe + vignette as a static layer | free |
| `effect_06_shake_wrong.png` | panel judder + red screen flash on wrong (v3 has shake; flash is new) | 0 idle |

Design-trend sources: dribbble terminal-UI gallery, cool-retro-term, Imetomi/retro-futuristic-ui-design,
classic hacker terminal aesthetic (phosphor #33FF33 / amber #FFB000), CSS glitch technique writeups.
