#!/usr/bin/env python3
"""Execute every module's scripts against the live lab container and report.

Contract: scripts live in modules/NN-slug/scripts/, run in lexical order.
  *.sql  -> executed statement-by-statement via python-oracledb (thin) as LAB_USER.
            PL/SQL blocks end with a line containing only '/'; plain SQL ends ';'.
            SELECT output rows whose first column starts with 'ASSERT:' are assertions;
            rows whose first column is 'METRIC:<name>:<value>' are measurements.
  *.js   -> executed with mongosh inside the lab container (LAB_CONTAINER, default
            lab-oracle) against the MongoDB API (port 27017). Lines printed as
            'ASSERT:<name>:PASS|FAIL' are assertions; 'METRIC:<name>:<value>' are
            measurements.
  *.sh   -> executed on the host with bash (e.g. a deployment step that recycles
            the API tier). Printed lines are graded like *.js output; rc != 0 is
            a script error. The SQL connection is reopened after each *.sh script.
Exit code 0 iff every assertion in every module is PASS and no script errors.
A METRIC line that does not parse, or a METRIC name repeated within a module,
is a script error; otherwise metrics never affect the exit code.
Writes validator/results.json, including "metrics": {module: {name: value}}.
"""
import json, os, re, subprocess, sys, time
import oracledb

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DSN = os.environ.get("LAB_DSN", "localhost:1521/FREEPDB1")
USER = os.environ.get("LAB_USER", "LAB_USER")
PWD = os.environ.get("LAB_PASSWORD", "LabUser2026")
CONTAINER = os.environ.get("LAB_CONTAINER", "lab-oracle")
# retryWrites=false is required: the Oracle MongoDB API rejects writes from
# clients that negotiate retryable writes (mongosh's default).
MONGO_URI = os.environ.get(
    "LAB_MONGO_URI",
    f"mongodb://{USER}:{PWD}@localhost:27017/{USER.lower()}"
    "?authMechanism=PLAIN&authSource=$external&tls=false&loadBalanced=true&retryWrites=false",
)

_CELL = re.compile(r"^(?:ASSERT:([\w-]+):(PASS|FAIL)|METRIC:([\w-]+):(\S+))$")

def parse_cell(cell):
    """Classify one output cell or printed line.

    ('assert', name, 'PASS'|'FAIL') for ASSERT:name:PASS|FAIL,
    ('metric', name, value)          for METRIC:name:value,
    None for anything else.
    """
    m = _CELL.match(cell.strip())
    if not m:
        return None
    if m.group(1):
        return ("assert", m.group(1), m.group(2))
    return ("metric", m.group(3), m.group(4))

def scan_metric(line, metrics, errors):
    """Record a METRIC line into metrics; anything else is ignored.

    results.json is the article's only source of numbers, so a line that starts
    with 'METRIC:' but does not parse, or that repeats a name, is an error.
    """
    if not line.strip().startswith("METRIC:"):
        return
    parsed = parse_cell(line)
    if parsed is None or parsed[0] != "metric":
        errors.append(f"malformed metric: {line.strip()!r}")
        return
    _, name, value = parsed
    if name in metrics:
        errors.append(f"duplicate metric {name!r}: {metrics[name]} then {value}")
        return
    metrics[name] = value

def merge_metrics(module_metrics, script_metrics, script):
    """Merge one script's metrics into its module's; return duplicate-name errors."""
    errors = []
    for name, value in script_metrics.items():
        if name in module_metrics:
            errors.append(f"{script}: duplicate metric {name!r} in module "
                          f"(already {module_metrics[name]}, now {value})")
        else:
            module_metrics[name] = value
    return errors

def _collect(cell, asserts, metrics, errors):
    # ASSERT cells are kept verbatim, exactly as before parse_cell existed, so a
    # malformed ASSERT still surfaces in results.json instead of vanishing.
    if cell.startswith("ASSERT:"):
        asserts.append(cell)
        return
    scan_metric(cell, metrics, errors)

def split_sql(text):
    """Yield executable statements. PL/SQL blocks end with a line '/'; plain SQL ends ';'.

    Standalone '--' comment lines before a statement's first code line are
    dropped, so every yielded statement starts with code (otherwise a leading
    comment would defeat the SELECT/WITH fetch check in run_sql and silently
    swallow assertions). Comments inside a statement are kept — legal SQL.
    """
    buf, in_plsql, has_code = [], False, False
    for line in text.splitlines():
        stripped = line.strip()
        if not has_code and stripped.startswith("--"):
            continue  # leading comments never attach to the next statement
        if not has_code and re.match(r"^(DECLARE|BEGIN|CREATE\s+(OR\s+REPLACE\s+)?(FUNCTION|PROCEDURE|PACKAGE|TRIGGER))",
                                stripped, re.I):
            in_plsql = True
        if in_plsql and stripped == "/":
            yield "\n".join(buf); buf, in_plsql, has_code = [], False, False
            continue
        buf.append(line)
        if stripped:
            has_code = True
        if not in_plsql and stripped.endswith(";") and not stripped.startswith("--"):
            stmt = "\n".join(buf).strip().rstrip(";")
            if stmt:
                yield stmt
            buf, has_code = [], False
    rest = "\n".join(buf).strip()
    if rest and has_code:
        yield rest.rstrip("/").strip()

def run_sql(path, conn):
    asserts, errors, metrics = [], [], {}
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    cur = conn.cursor()
    row_errors = []
    for stmt in split_sql(text):
        try:
            cur.execute(stmt)
            if stmt.lstrip().upper().startswith(("SELECT", "WITH")):
                for row in cur.fetchall():
                    _collect(str(row[0]) if row else "", asserts, metrics, row_errors)
        except Exception as e:
            errors.append(f"{os.path.basename(path)}: {e}\n  stmt: {stmt[:200]}")
    conn.rollback()  # demos must leave the domain unchanged
    errors += [f"{os.path.basename(path)}: {e}" for e in row_errors]
    return asserts, errors, metrics

def run_js(path):
    # CONTAINER_ENGINE=podman for hosts where docker is not permitted (e.g. Oracle
    # laptops); CI keeps the docker default.
    engine = os.environ.get("CONTAINER_ENGINE", "docker")
    cmd = [engine, "exec", "-i", CONTAINER, "mongosh", "--quiet", MONGO_URI,
           "--file", "/dev/stdin"]
    with open(path, "rb") as fh:
        proc = subprocess.run(cmd, stdin=fh, capture_output=True, text=True, timeout=300)
    return _grade_output(path, "mongosh", proc)

def run_sh(path):
    """Run a host shell script with bash; grade its printed lines like JS output.

    Used for host-side steps such as recycling the API tier. Inherits the
    environment, so LAB_CONTAINER / CONTAINER_ENGINE reach the script.
    """
    proc = subprocess.run(["bash", path], capture_output=True, text=True, timeout=900)
    return _grade_output(path, "bash", proc)

def _grade_output(path, tool, proc):
    # Newline-joined so a final stdout line without '\n' cannot fuse with stderr.
    out = proc.stdout + "\n" + proc.stderr
    # Keep the historical substring match for ASSERT (a line may carry a
    # prefix); METRIC lines are taken whole-line via parse_cell.
    asserts = re.findall(r"ASSERT:[\w-]+:(?:PASS|FAIL)", out)
    metrics, metric_errors = {}, []
    for line in out.splitlines():
        scan_metric(line, metrics, metric_errors)
    errors = [] if proc.returncode == 0 else [f"{os.path.basename(path)}: {tool} rc={proc.returncode}\n{out[-800:]}"]
    errors += [f"{os.path.basename(path)}: {e}" for e in metric_errors]
    return asserts, errors, metrics

def main():
    t0 = time.time()
    results, ok, all_metrics = [], True, {}
    conn = oracledb.connect(user=USER, password=PWD, dsn=DSN)
    mod_dir = os.path.join(ROOT, "modules")
    for mod in sorted(os.listdir(mod_dir)):
        scripts = os.path.join(mod_dir, mod, "scripts")
        if not os.path.isdir(scripts):
            continue
        for script in sorted(os.listdir(scripts)):
            path = os.path.join(scripts, script)
            if script.endswith(".sql"):
                asserts, errors, metrics = run_sql(path, conn)
            elif script.endswith(".js"):
                asserts, errors, metrics = run_js(path)
            elif script.endswith(".sh"):
                asserts, errors, metrics = run_sh(path)
                # A host script may restart the database (e.g. recycling the
                # API tier), so later SQL scripts get a fresh connection.
                try:
                    conn.close()
                except Exception:
                    pass
                conn = oracledb.connect(user=USER, password=PWD, dsn=DSN)
            else:
                continue
            errors += merge_metrics(all_metrics.setdefault(mod, {}), metrics, script)
            fails = [a for a in asserts if a.endswith(":FAIL")]
            status = "PASS" if not fails and not errors else "FAIL"
            ok = ok and status == "PASS"
            results.append({"module": mod, "script": script, "status": status,
                            "assertions": asserts, "errors": errors})
            print(f"[{status}] {mod}/{script}  ({len(asserts)} assertions)")
            for e in errors:
                print(f"    ERROR {e}")
    conn.close()
    summary = {"validated_against": "Oracle AI Database 26ai Free (gvenzl 23.26.x image)",
               "elapsed_s": round(time.time() - t0, 1),
               "all_pass": ok, "results": results,
               "metrics": {m: v for m, v in all_metrics.items() if v}}
    with open(os.path.join(ROOT, "validator", "results.json"), "w") as f:
        json.dump(summary, f, indent=2)
    print(f"\n{'ALL PASS' if ok else 'FAILURES'} in {summary['elapsed_s']}s")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
