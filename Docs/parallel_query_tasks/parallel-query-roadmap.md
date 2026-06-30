# Parallel Query Roadmap

## First Review Target

The current branch should be presented as a staged prototype. The first
discussion should focus on whether MariaDB maintainers want the initial slice
to be:

- SQL admission and fallback diagnostics;
- worker lifecycle and resource controls;
- Q6 scalar aggregation;
- Q1 constrained grouped aggregation;
- handler scan API skeleton;
- InnoDB scan provider boundaries.

The current 4-commit branch is useful for discussion because it shows the full
Q1/Q6 prototype working end to end. A formal upstream merge request may still
need to be split into smaller review slices.

## Code Refactoring Before Formal Review

The implementation currently concentrates a large amount of prototype logic in
existing files, especially `sql/sql_select.cc`. Before a formal review, reduce
the invasive surface:

1. Extract common PQ state and worker lifecycle helpers.
2. Extract scalar aggregate and grouped aggregate merge helpers.
3. Extract scan-provider admission and descriptor setup helpers.
4. Keep comments in the surrounding MariaDB style.
5. Avoid unrelated formatting and comment-style churn.
6. Add focused MTR after each refactoring slice.

This refactoring should preserve the current Q1/Q6 behavior and should not
expand feature scope.

## Performance Follow-Up

Q6 local SF10 evidence shows useful speedup at DOP 4 but not linear scaling at
higher DOP. Follow-up work should focus on the row scan path before making
stronger performance claims:

- reduce row materialization overhead in the worker scan path;
- evaluate record-buffer fast scan for Q6;
- measure CPU, memory bandwidth, and InnoDB page-scan behavior;
- repeat SF10 and larger-scale tests on a larger host;
- report cold and warm runs separately.

## Feature Follow-Up

After the Q1/Q6 baseline is stable, possible staged feature work includes:

- broader scalar aggregate support;
- broader grouped aggregate support;
- secondary-index and ICP parity;
- reverse and ref access paths;
- partitioned-table hardening;
- full worker plan clone;
- joins and hash joins;
- derived tables, UNION, CTE, and subquery support;
- write-select and CTAS policy decisions;
- TaurusDB transport and EXPLAIN compatibility decisions.

Each item should be discussed and tested as a separate review slice.
