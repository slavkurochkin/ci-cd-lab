/**
 * A batch of work that stops between items when asked. Project 12.
 *
 * Kubernetes stops a pod by sending SIGTERM, waiting the grace period, then
 * sending SIGKILL. Stopping between items means the item in hand is finished
 * rather than cut in half, and the rest are left for the next attempt.
 */

export interface WorkResult {
  /** Items finished. */
  done: number;
  /** True if the signal stopped the batch before the end. */
  interrupted: boolean;
}

export async function processItems(
  count: number,
  handle: (index: number) => Promise<void>,
  signal: AbortSignal,
): Promise<WorkResult> {
  let done = 0;
  for (let index = 0; index < count; index++) {
    if (signal.aborted) {
      return { done, interrupted: true };
    }
    await handle(index);
    done++;
  }
  return { done, interrupted: false };
}

/**
 * Exit code for a batch. An interrupted batch must not exit 0: a Job counts
 * exit 0 as complete, and the items never processed would be forgotten.
 * 143 is 128 + SIGTERM (15), what a shell reports for a process the signal
 * killed.
 */
export function exitCodeFor(result: WorkResult): number {
  return result.interrupted ? 143 : 0;
}
