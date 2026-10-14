# AGENTS.md (.github/)

`workflows/ci.yml` builds with the `ox-setup` action, pinning `fixed-decimal` and
`exchange-core` from GitHub in that order, runs the tests and the quickstart, builds odoc
(warnings fail) and calls the shared `obj-magic` workflow.

- A new sibling dependency needs a line in the `pins:` block, in dependency order.
- Check a run with `gh run list --limit 1`; at most one `gh run watch <id> --exit-status`.
