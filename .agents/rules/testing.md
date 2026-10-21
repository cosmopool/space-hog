# Testing Rules

> Philosophy based on "Codin' Dirty" by Carson Gross — prefer integration tests over unit tests; test the API, not the implementation.

## Core Principle

**Test behavior through the public API, not internal functions.** A good test sets up a realistic scenario, exercises the system the way a user (or consuming code) would, and verifies the observable outcome. It should survive refactors of the internals without modification.

## Rules

### 1. Prefer integration tests to unit tests

- Default to integration tests: set up real state (DOM, database, request, etc.), trigger the behavior through the public entry point, and assert on the resulting state.
- Do NOT write a unit test for every function. Internal/private functions are implementation details — they are tested indirectly through the API.
- A test that calls an internal helper directly is a smell. Ask: "Can this be expressed as an API-level test instead?"

### 2. Don't write tests too early

- In new projects or new modules, hold off on building a large test suite until the core API and concepts have **crystallized**.
- Early on, abstractions are still in flux. Tests written against unstable abstractions will break repeatedly and discourage exploration.
- A small number of smoke/sanity tests early is fine. Exhaustive coverage early is not.

### 3. Once the API stabilizes, test it exhaustively

- When a module's public API has settled, write thorough integration tests covering its contracts, edge cases, and invariants.
- These tests express **higher-level invariants** that should remain true regardless of how the code is implemented.

### 4. Test-drive at the API level, not the unit level

- TDD is allowed — but at the level of the API you want to achieve, not individual units of code.
- Workflow: design the desired API → write integration tests for that API → implement it however you see fit.
- Do NOT follow the strict "failing unit test before any production code" cycle from Clean Code.

### 5. Reproduce bugs and demonstrate features with high-level tests

- When fixing a bug, first write an integration test that reproduces it through the public API. This test has a longer shelf life than a unit-level reproduction.
- When adding a feature, prefer demonstrating it with an integration test over unit tests of its internals.

### 6. Keep test infrastructure lean

- Be suspicious of accumulating test helpers, mocks, stubs, and fixtures. They add mass and momentum that locks the codebase into a particular implementation.
- Prefer real collaborators over mocks whenever practical. Mock only at true system boundaries (network, clock, external services).
- If a test requires heavy mocking to work, it's probably testing implementation, not behavior — rewrite it at a higher level.

### 7. Tests must survive refactors

- The litmus test for any test: **"If I rewrite the implementation but keep the behavior, does this test still pass without changes?"**
- If the answer is no, the test is too coupled to the implementation. Raise its level of abstraction or delete it.

## Anti-patterns (avoid)

- One test file per source file, one test per function, as a matter of policy.
- Asserting on internal state, private fields, or call counts of internal functions.
- Large mock setups that mirror the internal structure of the code.
- Writing exhaustive tests against abstractions that haven't proven themselves yet.
- Refusing to delete tests that only verify implementation details.

## Quick checklist for new tests

1. Does the test go through the public API / entry point?
2. Does it assert on observable behavior or resulting state?
3. Would it survive an internal refactor unchanged?
4. Does it use real collaborators where practical?
5. Does it express an invariant worth keeping for the life of the project?
