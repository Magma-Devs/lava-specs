# Common Pitfalls

Sourced verbatim from `.claude/skills/review-spec/SPEC_GUIDE.md` lines 2031-2079.
Named antipatterns and "do not" rules learned from prior chain specs.

---

## Best Practices Summary

### Do's ✅
- **Test extensively** against live nodes before submission
- **Document everything** - future maintainers will thank you
- **Use inheritance** when appropriate to reduce duplication (see Step 3.1a for detailed mechanics)
- **Understand collection inheritance** - only define collections you need to customize
- **Let automatic inheritance work** - don't manually copy APIs from parent specs
- **Start with testnet** if unsure - lower stakes for testing
- **Engage community** early for feedback and support
- **Be precise** with block parsing - incorrect parsing breaks reliability
- **Benchmark accurately** - CU values affect provider economics
- **Include examples** in documentation for clarity
- **Version control** - track all changes with clear commits
- **Monitor after deployment** - be ready to issue updates

### Don'ts ❌
- **Don't guess** at parameters - measure and verify
- **Don't skip testing** - untested specs can harm the network
- **Don't over-complicate** - simpler specs are easier to maintain
- **Don't manually copy inherited collections** - if you want debug/trace from ETH1 unchanged, omit those collections entirely
- **Don't define collections unnecessarily** - automatic inheritance is your friend
- **Don't ignore existing patterns** - follow conventions from similar chains
- **Don't set deterministic=true** for non-deterministic APIs
- **Don't forget testnet** - providers need testing environments
- **Don't use mock data** - always test with real blockchain data
- **Don't rush governance** - give community time to review
- **Don't abandon** - be available for questions and updates
- **Don't duplicate work** - check if similar spec already exists

### Common Pitfalls to Avoid
1. **Misunderstanding Inheritance**: Manually defining collections that should be inherited automatically (read Step 3.1a carefully!)
2. **Incorrect Block Parsing**: Most common issue - verify parser positions. For REST APIs, use DEFAULT for most endpoints and EMPTY only for static/computation endpoints (see REST API Block Parsing Conventions)
3. **Wrong Determinism Flags**: Breaks data reliability if incorrect
4. **Unrealistic CU Values**: Causes economic imbalance — cross-check with `ethereum.json` and `tendermint.json` for similar operations
5. **Unnecessary Collection Definitions**: Defining debug/trace add-ons when inheriting from ETH1 unchanged
6. **Missing Verifications**: Allows invalid providers on network
7. **Incorrect Chain IDs**: Breaks chain verification entirely
8. **Poor Documentation**: Causes confusion and low adoption
9. **Inadequate Testing**: Leads to post-deployment issues
10. **Forgetting Extensions**: Archive nodes need proper configuration + pruning verification + GET_EARLIEST_BLOCK directive
11. **Hardcoded Values**: Use proper parameter references
12. **Incomplete API Coverage**: Frustrates users needing missing APIs
13. **Not Understanding CollectionData Matching**: Each `add_on` value creates a separate collection that inherits independently
14. **Blanket Content-Type Override**: Applying `pass_override` for content-type across a POST collection when different endpoints require different content-types (see Step 3.3a)
15. **Including Deprecated APIs**: Always check if the API provider has deprecated endpoints — use the non-deprecated replacement instead
16. **Including Platform-Specific APIs**: Health checks, usage metrics, and admin endpoints from third-party providers are not chain data and should be excluded
17. **Assuming Override Semantics**: All collection fields (headers, extensions, parse_directives, verifications) use **merge** semantics, not override. Empty arrays inherit parent values — they don't zero them out (see Step 3.1a)


END-OF-PITFALLS-SENTINEL
