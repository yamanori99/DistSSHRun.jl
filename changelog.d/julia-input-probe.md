category: changed

- Declared-input probes run in one remote Julia helper (`JULIA_LOAD_PATH=@stdlib`,
  empty `JULIA_DEPOT_PATH`) instead of `sha256sum` / `shasum`. Digests stay
  SHA-256. The controller uses OpenSSL EVP when it loads, and stdlib `SHA`
  otherwise. `check_input_manifest` streams file bytes.
