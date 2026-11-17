category: changed

- Shipped regular files stay read-only after pack and verified extract: non-executable files are mode `0444`, and files with any execute bit in the source are `0555` (still no write for owner/group/other). Verified extract applies modes from `executable_ship_rels`, not from tar umask-stripped permissions. Deploy records list `executable_ship_rels`; `content_tree_hash` and per-file mode checks still fail closed on tamper.
