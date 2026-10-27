category: fixed

- `setup` exits 1 when more than one mode flag is passed. The message names those two flags and `help setup`, and parsing stops at the second flag. `plan`, `pool`, and `size` exit 1 on an unknown `-` option before any other argument is applied, including when `-h` or `--help` is also present. The message names that option and `help plan`, `help pool`, or `help size`. `-h` and `--help` still print help when every flag is known. `setup` already rejected an unknown option; that message now names `help setup`.
