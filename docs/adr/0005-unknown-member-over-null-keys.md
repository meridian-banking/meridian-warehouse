# ADR 0005: Use unknown members rather than NULL foreign keys

## Status
Accepted — 2026-07

## Context
Facts sometimes reference a dimension record that has not loaded yet (a
"late-arriving dimension"), or a source value with no matching dimension row.
Three options exist:

1. Reject the fact row.
2. Load the fact with a NULL dimension key.
3. Point the fact at a designated "unknown" dimension row (key -1).

## Decision
Every dimension carries an unknown member. Fact loads use LEFT JOIN with
COALESCE to the unknown member's key.

## Rationale
- Option 1 loses real money movement. Unacceptable: the transaction happened.
- Option 2 is the dangerous one. Any INNER JOIN to that dimension silently drops
  those facts, so totals are quietly wrong with no error anywhere. Silent
  incorrectness is worse than visible incorrectness.
- Option 3 keeps the fact counted and surfaces the problem as an "Unknown"
  bucket on any report, where someone will notice and investigate.

## Consequences
+ Fact totals always reconcile to source totals.
+ Data quality problems become visible rather than silent.
- Reports show an "Unknown" category that must be explained to stakeholders.
- A rising unknown-member count is itself a monitoring signal worth alerting on
  (picked up by the Sprint 5 data-quality framework).

## Evidence this matters
During initial development, a bootstrapping bug made every dimension row valid
only from the load date, so all 200,000 historical facts failed the point-in-time
join. Because of this ADR they landed on the unknown member and the problem was
immediately visible as a count. Under option 2 the same bug would have silently
dropped every row from any inner-joined report.
