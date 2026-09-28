#!/usr/bin/env python3
"""Summarize opt-in LinkTrace JSONL captures without payloads or device identifiers."""
import argparse
from collections import Counter
import json
from pathlib import Path


def percentile(values, fraction):
    values = sorted(values)
    return round(values[min(len(values)-1, int((len(values)-1)*fraction))], 3) if values else None


def summarize(rows):
    requests = []
    active = 0
    concurrent = False
    for row in rows:
        if row['event'] == 'request.start':
            active += 1
            concurrent = concurrent or active > 1
        elif row['event'] == 'frame.receive' and row.get('type') in ('end','error'):
            active = max(0,active-1)
        elif row['event'] == 'stream.close': active = 0
    starts = [i for i, row in enumerate(rows) if row['event'] == 'request.start']
    for number, start in enumerate([] if concurrent else starts):
        stop = starts[number+1] if number+1 < len(starts) else len(rows)
        events = rows[start:stop]
        headers = next((r['us'] for r in events if r['event'] == 'frame.receive' and r.get('type') == 'response'), None)
        end = next((r['us'] for r in events if r['event'] == 'frame.receive' and r.get('type') in ('end', 'error')), None)
        if headers is None or end is None:
            requests.append({'round': number+1, 'complete': False})
            continue
        events = [r for r in events if r['us'] <= end]
        upload = [r for r in events if r['us'] <= headers]
        wait_us = sum(min(r['wait_us'], r['us']-rows[start]['us']) for r in upload if r['event'] == 'stream.resume')
        writes = [r for r in upload if r['event'] == 'stream.write' and r['bytes'] > 0]
        gaps = [(b['us']-a['us'])/1000 for a,b in zip(writes,writes[1:])]
        queued = 0
        remaining = rows[start]['bytes']
        in_flight = 0
        last = rows[start]['us']
        empty_wait = 0
        for row in upload:
            if remaining > 0 and in_flight > 0 and queued == 0:
                empty_wait += row['us'] - last
            if row['event'] == 'frame.enqueue': queued = row['queued']
            elif row['event'] == 'stream.write': queued = row['queued_before'] - max(0,row['bytes'])
            elif row['event'] == 'upload.state': remaining, in_flight = row['remaining'],row['in_flight']
            last = row['us']
        duration = headers - rows[start]['us']
        requests.append({
            'round': number+1, 'complete': True, 'bytes_each_direction': rows[start]['bytes'],
            'upload_ms': round(duration/1000,3), 'download_ms': round((end-headers)/1000,3),
            'output_space_wait_ms': round(wait_us/1000,3),
            'output_space_wait_percent_of_upload': round(100*wait_us/duration,2),
            'upload_queue_empty_with_unsent_body_ms': round(empty_wait/1000,3),
            'write_cpu_ms': round(sum(r['cpu_us'] for r in writes)/1000,3),
            'encode_cpu_ms': round(sum(r.get('encode_us',0) for r in events)/1000,3),
            'max_queued_bytes': max((r.get('queued',0) for r in events),default=0),
            'write_size_counts': dict(Counter(r['bytes'] for r in writes).most_common(8)),
            'write_gap_ms_p50_p90_p99_max': [percentile(gaps,p) for p in (.5,.9,.99,1)],
            'download_ack_delay_ms_p50_p99_max': [percentile([r['delay_us']/1000 for r in events if r['event']=='download.ack'],p) for p in (.5,.99,1)],
            'main_timer_gap_ms_p50_p99_max': [percentile([r['gap_us']/1000 for r in events if r['event']=='main.tick'],p) for p in (.5,.99,1)],
        })
    control = {}
    for kind in ('ack','bodyAck','ping','pong','settingsAck'):
        delays = [r['queue_us']/1000 for r in rows if r['event']=='frame.sent' and r['type']==kind]
        if delays:
            control[kind] = {'count': len(delays), 'queue_ms_p50_p90_max': [percentile(delays,p) for p in (.5,.9,1)]}
    return {'limit_reached': any(r['event']=='trace.limit' for r in rows),
            'request_analysis': 'skipped_concurrent_requests' if concurrent else 'sequential',
            'requests': requests, 'control_queue': control}


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture',type=Path)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    result=summarize([json.loads(line) for line in args.capture.read_text().splitlines() if line.strip()])
    data=json.dumps(result,ensure_ascii=False,indent=2)+'\n'
    if args.output: args.output.write_text(data)
    print(data,end='')
