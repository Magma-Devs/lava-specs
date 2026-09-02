# How a generated chain spec is tested

A chain spec is the config file that tells our router what a blockchain's API looks like — which methods
exist, what each costs, how to read a block number out of a response. When one is generated for a new
chain, it goes through an automated test pipeline before anyone reviews the pull request. This is what that
pipeline checks.

The pipeline is automated end to end: the research, the generation, the testing, the review passes and the
fixes are all done by AI agents. A human reads the results and decides what to do with them.

## The short answer

Five kinds of checking, run in order, cheapest first:

1. **Structure and internal consistency** — nine automated checks run in parallel over the file itself:
   required fields present, network timing parameters match their formulas, no duplicate method names,
   pricing follows the fixed conventions, archive/history settings sized against what the chain actually
   retains.

2. **Coverage against research** — the methods the chain's own documentation describes are diffed against
   the methods the spec declares. Anything missing has to be justified.

3. **Live testing against real nodes** ← *the core of it*. The spec is loaded into a real router, in
   Docker, pointed at the chain's public endpoints. The router has to start up and successfully track the
   chain. Then every method in the spec is called for real, through the router, and classified. Websocket
   subscriptions are opened and waited on. Block time is measured against the live chain and compared to
   what the spec claims. This is where defects that look fine on paper actually surface.

4. **Independent review** — four separate reviewers audit the file: three in parallel, then a fourth with
   the earlier reports hidden so it can't be anchored by them. They check the same nine areas a human
   reviewer would, having read the live-test results.

5. **Regression check** — after any fixes are applied, the fast file-level checks from step 1 are re-run,
   then the router is booted again and a fixed sample re-tested. Both halves matter: the fix pass is itself
   a likely source of new defects, because it applies instructions field by field without seeing the
   surrounding context.

## What stops the run

- **The router must boot** against the real chain. If it can't, the run stops there — nothing goes forward for review.
- **The final review must come back with zero critical and zero medium findings.** Anything else is
  "changes requested" and the run stops — there is deliberately no retry loop that keeps trying until it
  passes.
- **A regression after a fix stops the run** rather than shipping the fix.

Deliberate limits worth knowing about: there is a single fix pass, not a loop. The cheap file-level checks
from step 1 are re-run afterwards to catch anything the fix itself introduced, but the checks that need a
live chain or a running router are not — the two review rounds are what catch those.

**These stop the pipeline, not the merge button.** Two safety checks run as CI steps and fail the build,
but the review verdict itself is posted to the pull request as a comment — acting on it is a human
decision. "Changes requested" and merged anyway is possible, and worth asking about if you see it.

## What is not covered

| Not tested | Why | Who covers it |
|---|---|---|
| Transaction-sending methods | Calling them would broadcast a real transaction and move funds | Manual test on a funded testnet, if it matters for that chain |
| Testnet method coverage | The testnet entry gets startup checks only — its chain identity is verified live, but its methods are never called | Manual, if the testnet matters commercially |
| gRPC methods end-to-end | A technical limitation of the router's gRPC listener; those methods are tested against the node directly instead | Manual verification |
| Cost-per-call accuracy under load | Pricing is assigned by category, never benchmarked | A benchmarking exercise, if billing accuracy becomes a concern |
| Full response-parsing validation | Methods are confirmed to exist and respond; exhaustively validating every field needs production traffic | Production monitoring |

A method that fails when called is **not** removed from the spec. The pipeline only tests free public
endpoints, where a failure often means the free tier doesn't offer that method rather than the chain
lacking it. Removing one requires documented proof it doesn't exist.

Two further checks have no automated coverage at all and depend on the reviewer: that long-running methods
declare a timeout, and that only genuinely state-changing methods are marked as such.

There is also a known reporting weakness: one of the CI safety checks silently skips if it isn't present on
the branch being tested, and in a CI log a skip looks like a pass.

## Which specs this applies to

Everything above describes specs generated or reworked **through this pipeline**. Most of the spec files in
the repository predate it and have no test record at all. Coverage also varies legitimately by change type — a mechanical edit across several specs with no behavioural change won't
trigger the live-testing stage.

So "is this spec tested?" and "does our catalogue get tested?" are different questions with different
answers.

## Where the record is

Test results are not stored in the repository. The durable record for any given spec is the set of
automated comments on the pull request that introduced it — one per stage, including the full
method-by-method results table. If a spec's PR has no such comments, it has no recorded testing.

---

*Detail: the companion document `SPEC_TESTS.md` lists every individual check, what it proves, and what
happens when it fails.*
