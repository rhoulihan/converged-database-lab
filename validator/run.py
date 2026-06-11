#!/usr/bin/env python3
"""Execute every module's scripts against the live lab container and report.

Contract: scripts live in modules/NN-slug/scripts/, run in lexical order.
  *.sql  -> executed statement-by-statement via python-oracledb (thin) as LAB_USER.
            PL/SQL blocks end with a line containing only '/'; plain SQL ends ';'.
            SELECT output rows whose first column starts with 'ASSERT:' are assertions.
  *.js   -> executed with mongosh inside the lab-oracle container against the
            MongoDB API (port 27017). Lines printed as 'ASSERT:<name>:PASS|FAIL'
            are assertions.
Exit code 0 iff every assertion in every module is PASS and no script errors.
Writes validator/results.json.
"""
import json, os, re, subprocess, sys, time
import oracledb

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DSN = os.environ.get("LAB_DSN", "localhost:1521/FREEPDB1")
USER = os.environ.get("LAB_USER", "LAB_USER")
PWD = os.environ.get("LAB_PASSWORD", "LabUser2026")
# retryWrites=false is required: the Oracle MongoDB API rejects writes from
# clients that negotiate retryable writes (mongosh's default).
MONGO_URI = os.environ.get(
    "LAB_MONGO_URI",
    f"mongodb://{USER}:{PWD}@localhost:27017/{USER.lower()}"
    "?authMechanism=PLAIN&authSource=$external&tls=false&loadBalanced=true&retryWrites=false",
)

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
    asserts, errors = [], []
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    cur = conn.cursor()
    for stmt in split_sql(text):
        try:
            cur.execute(stmt)
            if stmt.lstrip().upper().startswith(("SELECT", "WITH")):
                for row in cur.fetchall():
                    cell = str(row[0]) if row else ""
                    if cell.startswith("ASSERT:"):
                        asserts.append(cell)
        except Exception as e:
            errors.append(f"{os.path.basename(path)}: {e}\n  stmt: {stmt[:200]}")
    conn.rollback()  # demos must leave the domain unchanged
    return asserts, errors

def run_js(path):
    cmd = ["docker", "exec", "-i", "lab-oracle", "mongosh", "--quiet", MONGO_URI,
           "--file", "/dev/stdin"]
    with open(path, "rb") as fh:
        proc = subprocess.run(cmd, stdin=fh, capture_output=True, text=True, timeout=300)
    out = proc.stdout + proc.stderr
    asserts = re.findall(r"ASSERT:[\w-]+:(?:PASS|FAIL)", out)
    errors = [] if proc.returncode == 0 else [f"{os.path.basename(path)}: mongosh rc={proc.returncode}\n{out[-800:]}"]
    return asserts, errors

def main():
    t0 = time.time()
    results, ok = [], True
    conn = oracledb.connect(user=USER, password=PWD, dsn=DSN)
    mod_dir = os.path.join(ROOT, "modules")
    for mod in sorted(os.listdir(mod_dir)):
        scripts = os.path.join(mod_dir, mod, "scripts")
        if not os.path.isdir(scripts):
            continue
        for script in sorted(os.listdir(scripts)):
            path = os.path.join(scripts, script)
            if script.endswith(".sql"):
                asserts, errors = run_sql(path, conn)
            elif script.endswith(".js"):
                asserts, errors = run_js(path)
            else:
                continue
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
               "all_pass": ok, "results": results}
    with open(os.path.join(ROOT, "validator", "results.json"), "w") as f:
        json.dump(summary, f, indent=2)
    print(f"\n{'ALL PASS' if ok else 'FAILURES'} in {summary['elapsed_s']}s")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
