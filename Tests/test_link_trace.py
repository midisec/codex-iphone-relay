import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('link_analysis', Path(__file__).resolve().parents[1] / 'scripts/analyze_link_trace.py')
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)


class LinkTimingTests(unittest.TestCase):
    def test_backpressure_and_empty_window_are_distinct(self):
        rows = [
            dict(event='request.start', us=0, bytes=100),
            dict(event='frame.enqueue', us=10, bytes=100, queued=100, type='body'),
            dict(event='upload.state', us=11, remaining=100, in_flight=4),
            dict(event='stream.wait', us=20, queued=100),
            dict(event='stream.resume', us=920, wait_us=900, queued=100),
            dict(event='stream.write', us=930, bytes=100, queued_before=100, cpu_us=10),
            dict(event='upload.state', us=1130, remaining=0, in_flight=0),
            dict(event='frame.receive', us=1200, type='response'),
            dict(event='frame.receive', us=2400, type='end'),
        ]
        row = analysis.summarize(rows)['requests'][0]
        self.assertEqual(row['output_space_wait_percent_of_upload'], 75)
        self.assertEqual(row['upload_queue_empty_with_unsent_body_ms'], .2)
        self.assertEqual(row['write_cpu_ms'], .01)
        self.assertEqual(row['download_ms'], 1.2)

    def test_incomplete_request_has_no_invented_throughput(self):
        row = analysis.summarize([dict(event='request.start', us=0, bytes=100)])['requests'][0]
        self.assertEqual(row, dict(round=1, complete=False))

    def test_ack_queue_includes_time_after_local_http_accepts_it(self):
        result = analysis.summarize([
            dict(event='download.ack', us=10, delay_us=100),
            dict(event='frame.sent', us=5000, queue_us=4900, type='ack'),
            dict(event='trace.limit', us=6000),
        ])
        self.assertEqual(result['control_queue']['ack']['queue_ms_p50_p90_max'], [4.9, 4.9, 4.9])
        self.assertTrue(result['limit_reached'])

    def test_overlap_never_pairs_headers_with_another_requests_end(self):
        result = analysis.summarize([
            dict(event='request.start', us=0, bytes=100),
            dict(event='request.start', us=100, bytes=100),
            dict(event='frame.receive', us=200, type='response'),
            dict(event='frame.receive', us=300, type='end'),
            dict(event='frame.receive', us=400, type='response'),
            dict(event='frame.receive', us=500, type='end'),
        ])
        self.assertEqual(result['requests'], [])
        self.assertEqual(result['request_analysis'], 'skipped_concurrent_requests')
