/**
 * Retry with exponential backoff and full jitter.
 *
 * Deliberately the kind of code that is easy to get subtly wrong and easy to
 * test: the CI/CD labs need a unit suite with real branches in it.
 */

export interface RetryOptions {
  /** Total attempts, including the first one. Must be >= 1. */
  attempts: number;
  /** Delay before the first retry, in milliseconds. */
  baseDelayMs: number;
  /** Upper bound on any single delay, in milliseconds. */
  maxDelayMs: number;
  /** Injected for tests. Returns a value in [0, 1). */
  random?: () => number;
  /** Injected for tests. Resolves after the given number of milliseconds. */
  sleep?: (ms: number) => Promise<void>;
}

export const DEFAULT_RETRY: RetryOptions = {
  attempts: 3,
  baseDelayMs: 100,
  maxDelayMs: 2000,
};

const defaultSleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));

/** Delay before retry number `attempt` (1-indexed), capped and jittered. */
export function backoffDelay(attempt: number, options: RetryOptions): number {
  if (attempt < 1) {
    throw new RangeError("attempt must be >= 1");
  }
  const random = options.random ?? Math.random;
  const exponential = options.baseDelayMs * 2 ** (attempt - 1);
  const capped = Math.min(exponential, options.maxDelayMs);
  return Math.floor(random() * capped);
}

/** Only transient failures are worth retrying; a 400 will still be a 400. */
export function isRetryable(error: unknown): boolean {
  if (error instanceof RangeError || error instanceof TypeError) {
    return false;
  }
  const status = (error as { status?: number } | null)?.status;
  if (typeof status === "number") {
    return status === 429 || status >= 500;
  }
  return true;
}

export async function withRetry<T>(
  operation: () => Promise<T>,
  options: RetryOptions = DEFAULT_RETRY,
): Promise<T> {
  if (options.attempts < 1) {
    throw new RangeError("attempts must be >= 1");
  }
  const sleep = options.sleep ?? defaultSleep;
  let lastError: unknown;

  for (let attempt = 1; attempt <= options.attempts; attempt++) {
    try {
      return await operation();
    } catch (error) {
      lastError = error;
      if (!isRetryable(error) || attempt === options.attempts) {
        throw error;
      }
      await sleep(backoffDelay(attempt, options));
    }
  }

  throw lastError;
}
