# AtomHealth

## iPhone app design rules (ios/AtomHealthSync/Sources)
Overview, Chat and Sync must look like one app. Keep them that way:
- Every main screen uses `.brandedScreen(title:)` (Brand.swift): inline title, icon + AtomHealth lockup leading, grouped background. No custom nav bars, large titles, or `Form` main screens.
- Brand: `Brand.gradient` (indigo 2B2A83 → blue 1D5FC0 → teal 14B8A6). `Theme.accent` is brand blue. No purple.
- Gradient is used for: `BrandHero` banner, `BrandButtonStyle` primary buttons, sent chat bubbles, send/camera buttons, raised Chat tab button.
- Content lives in `Card`s (16pt padding, 14pt spacing, 18pt radius) on `systemGroupedBackground`.
- Add `.appTabBar(model)` to each tab screen. Health/zone colours: `Theme.zone`, `HealthPalette` only.
- Check all three tabs, light and dark, after any UI change.
