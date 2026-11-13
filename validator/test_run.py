from run import parse_cell
def test_assert(): assert parse_cell("ASSERT:x-y:PASS") == ("assert", "x-y", "PASS")
def test_metric(): assert parse_cell("METRIC:s1-doc-k10:7") == ("metric", "s1-doc-k10", "7")
def test_other(): assert parse_cell("hello") is None
