// Cache paths and keys matching julia-actions/cache v3.5.0 (main.ts).
import fs from "fs";
import os from "os";
import path from "path";

function truthy(v) {
  return v === "true" || v === "1";
}

function expandDepot(depot) {
  let depotPath = depot || process.env.JULIA_DEPOT_PATH?.split(os.platform() === "win32" ? ";" : ":")[0] || "";
  if (!depotPath) depotPath = path.join(os.homedir(), ".julia");
  if (depotPath.startsWith("~")) {
    depotPath = path.join(os.homedir(), depotPath.slice(1));
  }
  if (process.platform === "win32") {
    depotPath = depotPath.replace(/\\/g, "/");
  }
  return depotPath;
}

function flattenMatrix(obj, prefix = "") {
  const result = [];
  for (const [key, value] of Object.entries(obj)) {
    const newKey = prefix ? `${prefix}-${key}` : key;
    if (typeof value === "object" && value !== null && !Array.isArray(value)) {
      result.push(...flattenMatrix(value, newKey));
    } else {
      result.push(`${newKey}=${value}`);
    }
  }
  return result;
}

function buildPaths(depotPath, opts) {
  const cachePaths = [];
  const push = (p) => cachePaths.push(p);
  if (opts.cacheArtifacts) push(`${depotPath}/artifacts`);
  if (opts.cachePackages) push(`${depotPath}/packages`);
  if (opts.cacheRegistries) {
    const registriesPath = `${depotPath}/registries`;
    if (fs.existsSync(registriesPath)) {
      process.stderr.write(
        "julia-depot-cache: registries already exist; skip restoring cached registries\n",
      );
    } else {
      push(registriesPath);
    }
  }
  if (opts.cacheCompiled) push(`${depotPath}/compiled`);
  if (opts.cacheScratchspaces) push(`${depotPath}/scratchspaces`);
  if (opts.cacheLogs) push(`${depotPath}/logs`);
  if (opts.cacheObjcache) push(`${depotPath}/cache`);

  push(`!${depotPath}/artifacts/*.pid`);
  push(`!${depotPath}/artifacts/*.pidfile`);
  push(`!${depotPath}/compiled/v*.*/*.pid`);
  push(`!${depotPath}/compiled/v*.*/*.pidfile`);
  push(`!${depotPath}/compiled/v*.*/*/*.pid`);
  push(`!${depotPath}/compiled/v*.*/*/*.pidfile`);
  push(`!${depotPath}/packages/*/*.pid`);
  push(`!${depotPath}/packages/*/*.pidfile`);
  push(`!${depotPath}/registries/*/.pid`);
  push(`!${depotPath}/registries/*/.pidfile`);
  push(`!${depotPath}/logs/*.pid`);
  push(`!${depotPath}/logs/*.pidfile`);
  push(`!${depotPath}/cache/v*.*/*/lock.mdb`);

  return cachePaths;
}

const depotPath = expandDepot(process.env.DEPOT || "");
const cacheName =
  process.env.CACHE_NAME ||
  `julia-cache;workflow=${process.env.GITHUB_WORKFLOW};job=${process.env.GITHUB_JOB}`;
const keyPrefix = process.env.KEY_PREFIX || "";
const includeMatrix = truthy(process.env.INCLUDE_MATRIX ?? "true");
const runnerOS = process.env.RUNNER_OS || "Linux";
const runId = process.env.GITHUB_RUN_ID || "0";
const runAttempt = process.env.GITHUB_RUN_ATTEMPT || "1";

const opts = {
  cacheArtifacts: truthy(process.env.CACHE_ARTIFACTS ?? "true"),
  cachePackages: truthy(process.env.CACHE_PACKAGES ?? "true"),
  cacheRegistries: truthy(process.env.CACHE_REGISTRIES ?? "true"),
  cacheCompiled: truthy(process.env.CACHE_COMPILED ?? "true"),
  cacheScratchspaces: truthy(process.env.CACHE_SCRATCHSPACES ?? "false"),
  cacheLogs: truthy(process.env.CACHE_LOGS ?? "true"),
  cacheObjcache: truthy(process.env.CACHE_OBJCACHE ?? "true"),
};

const paths = buildPaths(depotPath, opts);

let matrixKey = "";
const matrixJson = process.env.MATRIX_JSON || "null";
if (includeMatrix && matrixJson !== "null") {
  try {
    const matrix = JSON.parse(matrixJson);
    matrixKey = flattenMatrix(matrix).join(";") + ";";
  } catch (e) {
    process.stderr.write(`julia-depot-cache: matrix JSON parse failed: ${e}\n`);
  }
}

let restoreKey = `${keyPrefix}${cacheName};os=${runnerOS};${matrixKey}`;
restoreKey = restoreKey.replace(/,/g, "%2C");
const cacheKey = `${restoreKey}run_id=${runId};run_attempt=${runAttempt}`;

const out = process.env.GITHUB_OUTPUT;
if (!out) {
  process.stderr.write(`depot=${depotPath}\ncache-key=${cacheKey}\nrestore-key=${restoreKey}\n`);
  process.exit(0);
}

const delim = `paths_${Math.random().toString(36).slice(2)}`;
fs.appendFileSync(out, `paths<<${delim}\n${paths.join("\n")}\n${delim}\n`);
fs.appendFileSync(out, `cache-key=${cacheKey}\n`);
fs.appendFileSync(out, `restore-key=${restoreKey}\n`);
fs.appendFileSync(out, `depot=${depotPath}\n`);
fs.appendFileSync(out, `cache-registries=${opts.cacheRegistries}\n`);
