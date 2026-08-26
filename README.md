# Tokenomics

A super-lightweight native macOS **menu bar** app that turns your AI coding-agent
token usage into a live "market terminal" — at-a-glance burn rate, an end-of-day
projection, day-over-day comparison, daily breakdowns, and subscription
break-even.

> Think iStat Menus, but for how many tokens (and how much $) your AI coding
> agents are eating each day.

It reads usage **directly from the local logs** Claude Code, Codex, and WorkBuddy
already write (`~/.claude`, `~/.codex`, `~/.workbuddy`) — Tokenomics keeps no usage
log of its own, only
a small parse cache. Per-day token and cost totals are verified to match
[`ccusage`](https://github.com/ryoppippi/ccusage) exactly.

## Features

- **Menu bar ticker** — today's total tokens and API-equivalent cost, refreshed
  every 60s, no Dock icon (`LSUIElement` agent).
- **Pop-open dashboard** (left-click the 🪙):
  - **Headline** — today's tokens · cost, plus an end-of-day **projection** and a
    `vs 7d` delta. The projection comes from your typical intraday *shape* (see
    below), not a naive clock-linear extrapolation.
  - **Intraday rate chart** — tokens / 5 min for today. Three styles (Settings):
    a clean line, a smooth area **stacked by token type**, or **stacked by model**
    (same vendor → same hue, different shades).
  - **Second-chart deck** — flip between (a) a **cumulative** curve of *today vs a
    typical day → projected* and (b) a **daily stacked-by-type bar chart** of the
    last 14 days. Click the chart or the page dots to switch; the choice persists.
  - **Subscription break-even** — per vendor (Claude, GPT), a progress bar to
    break-even plus the multiple already earned back this month (e.g. `7.8×`),
    month-to-date API-equivalent cost vs your plan's fee, and the day it broke even.
- **Reports** — a Day / Week / Month report window (calendar icon, or right-click →
  Reports…): the period's total tokens & cost, the change vs the previous period, an
  end-of-period projection while in progress, a daily stacked-bar chart, per-vendor
  and per-model breakdowns, active-day / busiest-day / streak stats, and
  copy-as-Markdown.
- **Durable history** — usage is archived locally so reports keep working after
  Claude clears its logs (Settings → *Keep a usage history*; on by default).
- **Settings** — Launch at Login, rate-chart style, history archive, and a per-vendor
  plan picker (preset tiers, a custom monthly amount, or API pay-as-you-go).
- **Sources** — Claude Code, Codex, and WorkBuddy, merged. Cost is always the **API-equivalent**
  amount (LiteLLM prices), so it's meaningful whether you're on a subscription or API.

## How it reads your usage

| Source | Location | Notes |
|--------|----------|-------|
| Claude Code | `$CLAUDE_CONFIG_DIR`, else `~/.config/claude` then `~/.claude` → `projects/**/*.jsonl` | Mirrors `ccusage`: globs all depths, dedups assistant turns by `message.id:requestId` keeping the max output, tags priority ("fast") turns at 6× price. Additional homes can be listed in `~/.config/tokenomics/sources.json`. |
| Codex | `~/.codex`, plus `$CODEX_HOME` when set → `sessions/**/rollout-*.jsonl` | `token_count` events are counted per turn (`last_token_usage`; sub-turns don't advance the session cumulative), bucketed by local day; old rollouts fall back to cumulative deltas. Additional homes can be listed in `~/.config/tokenomics/sources.json`. |
| WorkBuddy | `~/.workbuddy` → `projects/**/*.jsonl` | Every row carrying `providerData.rawUsage` is one billed request (a turn's `function_call` rows each carry their own usage); `prompt_tokens` includes the cached portion, so input = prompt − cache hit − cache write. Dedup by `messageId`. Additional homes can be listed in `~/.config/tokenomics/sources.json`. |
| Pricing | [LiteLLM](https://github.com/BerriAI/litellm) model price JSON | Fetched and disk-cached (refreshed at most daily); a bundled snapshot is the fallback. Cost is recomputed from live prices, so updating prices never needs a rebuild. |

Parsing is incremental: each file's parsed records are cached by `(mtime, size)`
and persisted as NDJSON under `~/Library/Caches/me.stfang.tokenomics/`, so only
changed log files are re-read on each refresh.

### Additional local environments

Tokenomics can merge usage from additional Codex, Claude, or WorkBuddy homes on the same Mac.
Create `~/.config/tokenomics/sources.json`; paths must be absolute or start with
`~/`, and point to the agent home (the directory containing `sessions/` or
`projects/`):

```json
{
  "version": 1,
  "additionalCodexHomes": ["~/.codex-work"],
  "additionalClaudeHomes": ["~/.claude-work"],
  "additionalWorkbuddyHomes": ["~/.workbuddy-work"]
}
```

The file is optional and local to that Mac. Missing paths, malformed files, and
unsupported versions are ignored; the built-in sources continue to work.

That cache is a *mirror* of the current logs — it drops records once Claude rotates
a file away. A separate **durable archive** keeps every record it has seen, in
month-segmented NDJSON under `~/Library/Application Support/me.stfang.tokenomics/`
(survives a Caches purge), so reports stay correct long after the source logs are
gone. Ingest is idempotent (collapse + whole-segment atomic rewrite), only token
counts are stored — never prompts, paths, or keys — and it's ~5 MB/month. Toggle it
in Settings (on by default).

## Architecture

The compute core is pure and decoupled from presentation, so every surface (menu
bar today, a WidgetKit widget later) consumes the same normalized state.

```
Sources/Tokenomics/
├── Core/                 # pure engine — no AppKit/SwiftUI
│   ├── UsageProvider     # protocol: fetchDaily / fetchDailyByVendor / fetchDayMinuteMatrix
│   ├── ClaudeNativeProvider, CodexProvider, WorkBuddyProvider, CombinedProvider
│   ├── FileRecordCache   # generic (mtime,size) parse cache + NDJSON persistence
│   ├── Archive/          # durable per-record archive: ArchiveFile, ArchiveStore, UsageArchive
│   ├── LineReader        # O(n) streaming JSONL reader (handles multi-MB lines)
│   ├── Pricing / PricingStore
│   ├── Dashboard         # headline / recent-average
│   ├── IntradayCurve     # typical-shape model + end-of-day projection
│   ├── ReportPeriod / PeriodReport / ReportMarkdown   # day/week/month reports
│   ├── BreakEven / CostBasis
│   ├── DayBucket, TokenCounts, Format, UsageStore
├── UI/                   # SwiftUI views + view model (DashboardView, ReportView, SettingsView, ChartKit, …)
├── AppDelegate.swift     # NSStatusItem, popover, refresh orchestration
└── main.swift            # .accessory app entry + diagnostic flags
```

### The projection (how end-of-day is estimated)

For each of the last 14 days with data, the per-minute cumulative is normalized by
that day's total → a 0→1 "shape" curve; these are averaged into a **typical
shape**. The projection is `today's tokens so far ÷ typical fraction completed by
now`, extended along the typical shape to midnight. This captures sleep, lunch
dips, and front-/back-loaded days — the same idea as a stock terminal's
volume-profile (VWAP) forecast. (Below ~5% of a typical day completed, it shows
"warming up" instead of an unstable number.)

## Build & run

Requires macOS 14+ and a Swift 6 toolchain (Xcode 16+).

```bash
# Build a double-clickable .app bundle (release, ad-hoc signed, LSUIElement)
./scripts/build-app.sh
open dist/Tokenomics.app          # the 🪙 appears in the menu bar

# …or run straight from SPM during development
swift run
```

To launch automatically at login, toggle **Launch at Login** in Settings (it
registers via `SMAppService`; the app must live in a stable location such as
`/Applications`).

## Tests

```bash
swift test
```

A [swift-testing](https://github.com/swiftlang/swift-testing) suite (223 tests)
covers the Core engine with deterministic, timezone-independent inputs: the
projection math, break-even, the day-window trimming, the dedup-aware merge, the
parse cache (hit/miss + NDJSON round-trip), the durable archive (format, idempotent
ingest, backfill), the day/week/month report aggregation, and the formatters.

## Diagnostics

The binary exits early on these flags (used to verify the readers and profile):

| Flag | What it prints |
|------|----------------|
| `--dump-daily` | Claude per-day token + cost TSV (diff against `ccusage daily --json`) |
| `--dump-codex` | Codex per-day token + cost TSV |
| `--dump-workbuddy` | WorkBuddy per-day token + cost TSV |
| `--dump-intraday` | Today's non-empty 5-minute buckets (combined) |
| `--dump-curve` | Today / typical / projected end-of-day summary |
| `--dump-peers` | Each iCloud peer file's manifest + a structure check |
| `--dump-archive` | Each archive segment's manifest + a current-month Markdown report |
| `--scan-only` | Stream every Claude line without decoding (isolates reader memory) |
| `--bench` | Times a cold vs warm read on one provider |

```bash
.build/release/Tokenomics --dump-daily
```

## Footprint

Steady state ≈ **56 MB** memory (Activity Monitor) and **~0% CPU** while idle
(no polling between refreshes).

## Roadmap

- [x] Menu bar: today's tokens + cost, timer refresh
- [x] Native Claude Code reader (ccusage-exact), incremental parse cache
- [x] Codex reader
- [x] Live LiteLLM pricing
- [x] Intraday rate chart (line / stacked-by-type / stacked-by-model)
- [x] Cumulative typical-shape projection
- [x] Daily stacked-by-type bar chart
- [x] Per-vendor subscription break-even
- [x] Durable usage archive (survives Claude's log rotation)
- [x] Day / week / month report window with Markdown export
- [x] Core unit-test suite (swift-testing)
- [ ] Parser fixture tests (lock the dedup / fast / delta rules under `swift test`)
- [ ] Configurable refresh interval
- [ ] WidgetKit desktop widget, reusing the Core engine
