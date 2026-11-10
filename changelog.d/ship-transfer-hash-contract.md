category: fixed

- Document that `content_tree_hash` names the shipped tree only; files under
  `<dest>/.distssh/` are not included. Add an internal `transfer_tree` step-order
  test and remove the unused in-progress shipped-record writer.