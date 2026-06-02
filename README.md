# DailyToken

A super-lightweight native macOS **menu bar** app that turns your coding-agent
token usage into a live "market terminal" — at-a-glance burn rate, today's
projected consumption, day-over-day comparison, and subscription break-even.

> Think iStat Menus, but for how many tokens (and how much $) your AI coding
> agents are eating each day.

## Status

🚧 Early prototype. Phase 1: show today's token count in the menu bar, auto-refreshing.

## Vision

- **Menu bar ticker** — a glanceable number (and later a scrolling "quote" of
  burn rate / projection / break-even), always on, near-zero footprint.
- **Pop-open dashboard** — projection, day-over-day, per-model breakdown, cost.
- **Multi-source** — pluggable usage providers:
  - Claude Code (reads `~/.claude` JSONL, via `ccusage`)
  - Codex (reads `~/.codex` SQLite) — _planned_
- **Desktop widget** — WidgetKit, reusing the same core engine — _planned_

## Architecture

The compute core is decoupled from presentation so every surface (menu bar,
widget, …) consumes the same normalized state.

```
Core engine  →  today's usage / history / projection / cost  →  state
   │
   ├── menu bar  (NSStatusItem)        ← Phase 1
   ├── widget    (WidgetKit)           ← later
   └── …
```

## Tech

- Native **Swift** (AppKit `NSStatusItem`), built with Swift Package Manager —
  no Xcode required for the menu bar prototype.
- Full Xcode required later for the WidgetKit desktop widget.

## Roadmap

- [ ] Phase 1 — menu bar shows today's tokens, refreshes on a timer
- [ ] Pop-open detail (today tokens, cost, vs yesterday)
- [ ] Today's projection (linear → intraday-curve model)
- [ ] Subscription break-even view
- [ ] Codex provider
- [ ] Scrolling ticker animation
- [ ] WidgetKit desktop widget
