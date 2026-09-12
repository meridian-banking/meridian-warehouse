# ADR 0004: SCD Type 2 for dim_customer, Type 1 elsewhere

## Status
Accepted — 2026-07

## Context
Slowly changing dimensions can be handled several ways. Type 1 overwrites and
keeps no history. Type 2 keeps every version with validity windows. Type 2 costs
more storage, makes every query think about validity windows, and complicates
the load. So it should not be applied indiscriminately.

## Decision
`dim_customer` is Type 2. `dim_account` and `dim_branch` are Type 1.

Tracked (Type 2) customer attributes: name, age, income, credit score, credit
band, DTI, segment, home branch.

## Rationale
History is tracked where someone will actually ASK about history:
- Customer segment and credit band: needed for point-in-time reporting, fair
  lending audits ("what did you know when you made the decision?"), and
  underwriting-drift analysis. High analytical and regulatory value.
- Account product type / APR: effectively immutable for an existing account.
  No stakeholder asks what an account's product type was in 2022.

## Consequences
+ Point-in-time customer analysis is possible and correct.
+ Segment-migration analysis exists at all (impossible under Type 1).
- Every fact load must perform a point-in-time join rather than a simple key
  lookup. Joining on `is_current` instead is a silent correctness bug that
  discards the history — called out in code comments and covered by tests.
- dim_customer grows over time as versions accumulate.

## Revisit if
Account attributes start changing meaningfully (e.g. repricing campaigns that
alter APR on existing accounts), which would make account history worth keeping.
