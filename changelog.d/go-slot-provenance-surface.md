category: fixed

- Go-slot provenance loader failures now print to stderr and record an `error` field in `provenance-slot.toml` instead of failing silently; the user script still runs because a non-zero loader exit would fail the slot.
- `_flush_go_slot_pmap_items!` resolves `provenance-slot.toml` under legacy `.distsshkit/` and logs flush failures with `@warn` instead of swallowing them.
