export interface UpdateState {
  phase: string; version: string; build?: string; availableVersion?: string;
  received?: number; total?: number; message?: string;
}
export function downloadProgress(received: number, total: number): string {
  const size = (value: number) => value < 1024 ? `${Math.max(0,value)} B` : value < 1024 ** 2 ? `${(value/1024).toFixed(1)} KB` : `${(value/1024**2).toFixed(1)} MB`
  return total > 0 ? `${size(received)} / ${size(total)} (${Math.min(100,Math.max(0,Math.round(received/total*100)))}%)` : size(received)
}
