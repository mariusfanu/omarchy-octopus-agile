# Octopus Agile — Omarchy bar widget

Live Octopus Agile electricity prices in your bar.

- Pill shows the **current half-hour price** (` 12.3p ↑`), `…` while loading.
  Optional **↑ / ↓** for whether the next slot is more or less expensive.
- Click the pill for the popup: current + next price, min/avg/max,
  **cheapest 1h / 2h / 3h windows from now**, and a full-day 30-min bar chart.
- Footer has a **region picker (A–P)** — persisted to `shell.json` —
  plus refresh and Octopus dashboard buttons.
- Optional **cheap-window alerts** (off by default): a desktop notification
  before a slot below 10p, or any plunge. Click the toast to open the popup.
- Prices auto-refresh every 5 minutes; the current slot rolls over every 30s.
  Failed fetches back off (15s → 4m) before deferring to the next refresh.

## Install

```bash
omarchy plugin add https://github.com/mariusfanu/omarchy-octopus-agile.git --enable
```

That clones the plugin and places it on the bar. Pick your UK DNO region from the popup dropdown.

Optional Omarchy menu row — add this to `~/.config/omarchy/extensions/omarchy-menu.jsonc`:

```jsonc
"energy": {"icon":"","label":"Energy"},
"energy.octopus": {
  "icon": "",
  "label": "Octopus Agile",
  "action": "omarchy-shell io.github.mariusfanu.octopus-agile toggle",
  "description": "Live Agile prices, cheapest windows and day chart"
}
```

Toggle the popup without the menu:

```bash
omarchy-shell io.github.mariusfanu.octopus-agile toggle
```

## Remove

```bash
omarchy plugin remove io.github.mariusfanu.octopus-agile
```

That disables the widget and deletes the plugin checkout. It does not edit `omarchy-menu.jsonc`; remove any menu row you added yourself.

## Settings (`~/.config/omarchy/shell.json`)

```json
{
  "id": "io.github.mariusfanu.octopus-agile",
  "region": "C",
  "showTrend": true,
  "notifyCheap": false,
  "notifyLeadMin": 15,
  "notifyBelow": 10
}
```

- `region`: UK DNO letter A–P (default `C` London). Change it from the popup dropdown.
- `product`: optional override such as `AGILE-24-10-01` (must match `AGILE-[A-Z0-9-]+`; anything else is ignored). When empty the latest `AGILE-*` import product is auto-discovered.
- `showTrend`: `true` (default) shows ↑ / ↓ on the pill. Turn it off from the popup or Omarchy widget settings.
- `notifyCheap`: `false` (default). When `true`, notify before a cheap or plunge slot.
- `notifyLeadMin`: minutes ahead to warn (5–30, default 15).
- `notifyBelow`: notify when the upcoming slot is below this p/kWh (default 10). Plunge prices always notify when alerts are on.

## Files

- `manifest.json` — plugin declaration (`io.github.mariusfanu.octopus-agile`, `bar-widget`)
- `BarWidget.qml` — bar pill, hosts the popup
- `Panel.qml` — popup: hero, stats, cheapest windows, chart, region picker
- `Model.js` — pure logic (also runnable under `node` for tests)

## Data source

Official Octopus Energy API, no key needed:

- Products: `https://api.octopus.energy/v1/products/?is_variable=true`
- Rates: `.../products/{PRODUCT}/electricity-tariffs/E-1R-{PRODUCT}-{REGION}/standard-unit-rates/`

Prices shown inc. VAT in p/kWh, times in your local timezone.

## License

MIT. See [LICENSE](LICENSE).
