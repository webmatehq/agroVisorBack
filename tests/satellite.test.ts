import test from 'node:test';
import assert from 'node:assert/strict';
import {parseStatistics, STAT_SCRIPT} from '../src/providers.js';

test('retains provider standard deviation and handles missing statistics', () => {
  const interval = {from: '2026-10-01T00:00:00Z', to: '2026-10-02T00:00:00Z'};
  const [row, empty] = parseStatistics([
    {interval, outputs: {available: {bands: {B0: {stats: {sampleCount: 200, noDataCount: 100}}}}, ndvi: {bands: {B0: {stats: {mean: 0.4, min: 0.1, max: 0.8, stDev: 0.12, percentiles: {'50.0': 0.39}, sampleCount: 200, noDataCount: 110}, histogram: {bins: [{lowEdge: 0.2, highEdge: 0.4, count: 20}]}}}}}},
    {interval},
  ]);
  assert.equal(row.ndvi_stddev, 0.12);
  assert.equal(row.ndvi_median, 0.39);
  assert.deepEqual(row.ndvi_histogram, [{low: 0.2, high: 0.4, count: 20}]);
  assert.equal(row.valid_fraction, 0.9);
  assert.equal(empty.ndvi_stddev, null);
  assert.equal(empty.ndvi_median, null);
  assert.equal(empty.quality, 'no_data');
});

test('NDVI statistics use floating point output rather than AUTO', () => {
  assert.match(STAT_SCRIPT, /sampleType:"FLOAT32"/);
});
