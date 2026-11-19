# Commodore 64 theme — design

## Intent
Add a "Commodore 64" entry to the Phosphor picker: light-blue text on the blue
screen of the C64 power-on prompt. Nostalgia preset, same mechanism as green/amber/white.

## Goals
- Selectable from Preferences > Appearance > Phosphor.
- Old preference blobs keep decoding (no migration).

## Non-goals
- VIC-II 16-colour ANSI palette.
- Light-blue border around the screen.
- C64 font.

## Approaches
1. Tell users to pick "Custom" with the two colours. Already possible, not discoverable. Rejected.
2. New `PhosphorTheme.c64` case with label "Commodore 64" and colours in `phosphor` / `background`.
   Chosen: no new stored properties, `PhosphorTheme` is `Codable` by raw string so old prefs decode.

## Decisions
- Target look: the Colodore palette, text RGB 120/105/196 on background RGB 62/49/162, **as rendered**.
  The bloom pass has no threshold, so the whole background glows and brightens by about 1.45x;
  the configured values are therefore text RGB(0.55, 0.50, 0.92) and background RGB(0.17, 0.13, 0.45),
  which a full-resolution screenshot measured at RGB 64/49/170 on screen.
- Monochrome and Tinted colour modes dim ANSI colours by interpolating towards the screen background
  instead of scaling towards black. Identical on the near-black themes, needed here or `ls` colours vanish.
- Label: "Commodore 64".
- README phosphor line mentions the new theme.

## Verified
- Full-resolution screenshots in Monochrome and Tinted modes with the default effects: text, bold,
  reverse video, ANSI foregrounds and backgrounds all legible.
