from run import parse_cell, scan_metric, merge_metrics
def test_assert(): assert parse_cell("ASSERT:x-y:PASS") == ("assert", "x-y", "PASS")
def test_metric(): assert parse_cell("METRIC:s1-doc-k10:7") == ("metric", "s1-doc-k10", "7")
def test_other(): assert parse_cell("hello") is None

def test_malformed_metric_reported():
    m, e = {}, []
    scan_metric("METRIC:x:", m, e)
    assert m == {} and len(e) == 1 and "METRIC:x:" in e[0]

def test_non_metric_line_ignored():
    m, e = {}, []
    scan_metric("hello", m, e)
    scan_metric("ASSERT:x:PASS", m, e)
    assert m == {} and e == []

def test_duplicate_in_script_reported():
    m, e = {}, []
    scan_metric("METRIC:a:1", m, e)
    scan_metric(" METRIC:a:2 ", m, e)
    assert m == {"a": "1"} and len(e) == 1 and "duplicate" in e[0]

def test_duplicate_across_scripts_reported():
    mod = {"a": "1"}
    errs = merge_metrics(mod, {"a": "2", "b": "3"}, "02-x.sql")
    assert mod == {"a": "1", "b": "3"} and len(errs) == 1 and "a" in errs[0]

# Host shell scripts (*.sh): run with bash; printed lines graded like JS output.
import os, tempfile
from run import run_sh

def _sh(body):
    fd, path = tempfile.mkstemp(suffix=".sh")
    with os.fdopen(fd, "w") as fh:
        fh.write(body)
    return path

def test_sh_asserts_and_metrics_captured():
    p = _sh('echo "ASSERT:sh-ok:PASS"\necho "METRIC:sh-m:4"\necho noise\n')
    asserts, errors, metrics = run_sh(p)
    os.remove(p)
    assert asserts == ["ASSERT:sh-ok:PASS"] and errors == [] and metrics == {"sh-m": "4"}

def test_sh_nonzero_rc_is_error():
    p = _sh('echo "ASSERT:sh-x:PASS"\nexit 3\n')
    asserts, errors, metrics = run_sh(p)
    os.remove(p)
    assert asserts == ["ASSERT:sh-x:PASS"] and len(errors) == 1 and "rc=3" in errors[0]

def test_sh_malformed_metric_is_error():
    p = _sh('echo "METRIC:bad:" >&2\n')
    asserts, errors, metrics = run_sh(p)
    os.remove(p)
    assert asserts == [] and metrics == {} and len(errors) == 1 and "malformed" in errors[0]
