import sys
import os
import io
import importlib.util
import unittest


def load_module(rel_path):
    abs_path = os.path.join(os.path.dirname(__file__), '..', rel_path)
    spec = importlib.util.spec_from_file_location(rel_path, abs_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


top_mapper  = load_module('jobs/top_resources/mapper.py')
top_reducer = load_module('jobs/top_resources/reducer.py')
sb_mapper   = load_module('jobs/status_bytes/mapper.py')
sb_reducer  = load_module('jobs/status_bytes/reducer.py')


# Real-world samples from the NASA Kennedy Space Center Jul95 log
VALID_GET  = '133.43.96.45 - - [01/Jul/1995:00:00:23 -0400] "GET /images/NASA-logosmall.gif HTTP/1.0" 200 786'
VALID_POST = '205.212.115.106 - - [01/Jul/1995:00:01:42 -0400] "POST /login HTTP/1.0" 401 1420'
STATUS_304 = ('199.120.110.21 - - [01/Jul/1995:00:00:09 -0400] '
              '"GET /shuttle/missions/sts-73/mission-sts-73.html HTTP/1.0" 304 -')
MALFORMED  = 'this is not a valid CLF line at all'
# U+00FF (ÿ) in URL — exercises the errors="replace" path for Latin-1 stray bytes
LATIN1     = ('130.110.74.81 - - [01/Jul/1995:00:02:12 -0400] '
              '"GET /shuttle/countdown/count.gif\xff HTTP/1.0" 200 40310')


def run_module(mod, lines):
    """Run mod.main() with lines as stdin; return non-empty stdout lines."""
    _in, _out, _err = sys.stdin, sys.stdout, sys.stderr
    try:
        sys.stdin  = io.StringIO('\n'.join(lines) + '\n')
        sys.stdout = io.StringIO()
        sys.stderr = io.StringIO()
        mod.main()
        return [l for l in sys.stdout.getvalue().splitlines() if l]
    finally:
        sys.stdin, sys.stdout, sys.stderr = _in, _out, _err


class TestTopResourcesMapper(unittest.TestCase):

    def test_top_resources_mapper_emits_path_for_valid_line(self):
        # also feeds a Latin-1-byte URL to verify no crash
        out = run_module(top_mapper, [VALID_GET, LATIN1])
        self.assertIn('/images/NASA-logosmall.gif\t1', out)
        self.assertEqual(len(out), 2)

    def test_top_resources_mapper_skips_malformed_line(self):
        out = run_module(top_mapper, [MALFORMED])
        self.assertEqual(out, [])


class TestStatusBytesMapper(unittest.TestCase):

    def test_status_bytes_mapper_emits_zero_when_bytes_dash(self):
        out = run_module(sb_mapper, [STATUS_304])
        self.assertEqual(len(out), 1)
        status, _count, byte_count = out[0].split('\t')
        self.assertEqual(status, '304')
        self.assertEqual(byte_count, '0')

    def test_status_bytes_mapper_handles_post_with_path(self):
        out = run_module(sb_mapper, [VALID_POST])
        self.assertEqual(len(out), 1)
        status, _count, byte_count = out[0].split('\t')
        self.assertEqual(status, '401')
        self.assertEqual(byte_count, '1420')


class TestTopResourcesReducer(unittest.TestCase):

    def test_reducer_streaming_sum_aggregates_correctly(self):
        lines = [
            '/images/NASA-logosmall.gif\t47231',
            '/images/NASA-logosmall.gif\t64099',
            '/ksc.html\t18500',
        ]
        out = run_module(top_reducer, lines)
        self.assertIn('/images/NASA-logosmall.gif\t111330', out)
        self.assertIn('/ksc.html\t18500', out)


class TestStatusBytesReducer(unittest.TestCase):

    def test_reducer_status_bytes_aggregates_three_fields(self):
        lines = [
            '200\t1\t786',
            '200\t1\t1234',
            '304\t1\t0',
        ]
        out = run_module(sb_reducer, lines)
        self.assertIn('200\t2\t2020', out)
        self.assertIn('304\t1\t0', out)


if __name__ == '__main__':
    unittest.main()
