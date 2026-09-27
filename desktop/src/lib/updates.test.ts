import { expect, test } from 'vitest'
import { downloadProgress } from './updates'
test('small deltas show KB and bounded progress, unknown totals stay indeterminate', () => {
  expect(downloadProgress(2048,4096)).toBe('2.0 KB / 4.0 KB (50%)')
  expect(downloadProgress(4096,2048)).toBe('4.0 KB / 2.0 KB (100%)')
  expect(downloadProgress(1048576,0)).toBe('1.0 MB')
  expect(downloadProgress(0,0)).toBe('0 B')
})
