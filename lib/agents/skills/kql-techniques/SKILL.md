---
name: kql-techniques
description: Use when writing KQL queries, especially for timecharts and dashboards. Covers gap-free
  timecharts, adaptive bin sizing, rate normalization, series management, and message classification.
---

# KQL Techniques

## Gap-free timecharts with `make-series` + `mv-expand`

Raw `summarize ... by bin()` produces gaps where no data exists. For timecharts, use `make-series`
to create a complete time axis (zero-filling gaps), then `mv-expand` back to rows:

```kusto
| make-series Count=count() default=0 on Timestamp in range(startTime, endTime, binSize) by Case
| mv-expand Timestamp, Count
| project Timestamp=todatetime(Timestamp), Count=tolong(Count), Case
```

Contra-indicated when a constant value (like 0 in this example) is not the right representative for missing data.


## Adaptive bin sizing

Calculate bin size from the time range to keep ~300 data points, with a minimum floor:

```kusto
let minBinSize=20m;
let getBinSize = (duration:timespan) {
    let bs = duration / 300;
    max_of(
        minBinSize,
        case(bs < 1m, 1m, bs < 5m, 5m, bs < 10m, 10m, bs < 20m, 20m, bs < 30m, 30m,
             bs < 1h, 1h, bs < 2h, 2h, bs < 4h, 4h, bs < 12h, 12h, bs < 1d, 1d,
             bs < 7d, 7d, 30d)
    )
};
let binSize=getBinSize(requestedEndTime-requestedStartTime);
```


## Rate normalization

Report "per hour" or "per day" rates instead of raw bucket counts. Raw counts change meaning when
bin size changes; rates are stable across zoom levels:

```kusto
let binsPerHour = todouble(1h/binSize);
// ...
| project TimeStamp, EventsPerHour=Count*binsPerHour, Case
```


## Series ordering and filtering for chart widgets

Chart tools can struggle with many series. Join with totals to sort by
significance, then limit. For example:

```kusto
let cases=allSeries | summarize SeriesCount=sum(Count) desc by Case | take 100;
allSeries
| join kind=leftouter (cases) on Case
| order by SeriesCount desc, TimeStamp asc
| project TimeStamp, Value, Case
| render timechart
```


## Significance-weighted health scores

Avoid false alarms from low-traffic entities. Weight error rates by request volume using linear
interpolation:

```kusto
let lerp=(value:double, bottom:double, top:double) {
    iif(value <= bottom, 0.0, iif(value >= top, 1.0, (value - bottom) / (top - bottom)))
};
// significance ramps 0->1 as request count goes 5->20
| extend significance=lerp(todouble(Total), 5.0, 20.0)
| extend Health=round(100.0 * (1.0 - (errorRate * significance)), 2)
```


## Message classification with nested `case`

For classifying log messages into categories, use nested `case` functions with `has_cs` (case-sensitive)
for precise matching:

```kusto
let classify = (message:string) {
    case(
        message has_cs "specific error text", "Category A",
        message has_cs "other pattern",       "Category B",
        "unrecognized"
    )
};
```

Use `has_cs` over `has` when the same word appears in different cases with different meanings.


## `scan` for grouping sequential log entries

The `scan` operator tracks state across ordered rows. Use it to group consecutive log lines that
share a key into blocks:

```kusto
| order by TimeStamp asc
| scan declare (FirstTimeStamp: datetime)
    with (step s1: true =>
        FirstTimeStamp = iff((s1.Service == Service), s1.FirstTimeStamp, TimeStamp);)
| summarize Messages = make_set(strcat(Source, ": ", Message)) by FirstTimeStamp, Service
```

This collapses a log timeline into one row per service-burst, making phase transitions visible.


## `parse-where` for safe structured extraction

`parse-where` filters out non-matching rows (unlike `parse` which leaves nulls). Prefer it when
extracting from a specific message format:

```kusto
| parse-where Message with 'Initialized the foobar ' * 'Foobar Id: ' FooBarId:long ', baz' *
```

Limitation: less useful when a single query handles multiple message formats — you'd filter out
the rows that match a different pattern.


## Timespan arithmetic

`todouble(timespan)` returns **ticks** (1 tick = 100 ns). Common conversion constants:
- Minutes: `todouble(ts) / 600000000.0` (or simpler: `ts / 1m`)
- Hours: `todouble(ts) / 36000000000.0` (or: `ts / 1h`)

Prefer the `ts / 1m` form — it's a native Kusto timespan division that returns a double directly,
no `todouble()` needed, and no magic constants to get wrong.


## `project` vs `project-reorder` for MCP/API consumption

`project-reorder` keeps all columns (reordering the named ones to the front). This is useful for
**human exploration in ADX** — e.g. `| take 5 | project-reorder ImportantCol1, ImportantCol2` to
see key columns first while still discovering what other columns exist.

For **queries whose results will be consumed by an MCP tool or API** (where all columns are
returned as data), use `project` with an explicit column list instead. Otherwise, wide tables can produce multi-MB
responses that overwhelm context.


## `between` range variables

`datetime(x) .. datetime(y)` is a range literal — it cannot be assigned to a `let` variable.
Use two separate variables:

```kusto
let timeStart = datetime(2026-03-27);
let timeEnd = datetime(2026-03-31);
// ...
| where PreciseTimeStamp between(timeStart .. timeEnd)
```
