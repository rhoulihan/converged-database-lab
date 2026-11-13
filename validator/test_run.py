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
