import { describe, expect, it, vi } from "vitest";

import { DEFAULT_RETRY, backoffDelay, isRetryable, withRetry } from "../src/retry.ts";

const noSleep = async (): Promise<void> => {};

describe("backoffDelay", () => {
  const options = { ...DEFAULT_RETRY, baseDelayMs: 100, maxDelayMs: 1000, random: () => 0.999 };

  it("grows exponentially", () => {
    expect(backoffDelay(1, options)).toBe(99);
    expect(backoffDelay(2, options)).toBe(199);
    expect(backoffDelay(3, options)).toBe(399);
  });

  it("caps at maxDelayMs", () => {
    expect(backoffDelay(10, options)).toBe(999);
  });

  it("applies jitter", () => {
    expect(backoffDelay(3, { ...options, random: () => 0 })).toBe(0);
  });

  it("rejects attempt numbers below 1", () => {
    expect(() => backoffDelay(0, options)).toThrow(RangeError);
  });
});

describe("isRetryable", () => {
  it("retries 5xx and 429", () => {
    expect(isRetryable({ status: 503 })).toBe(true);
    expect(isRetryable({ status: 429 })).toBe(true);
  });

  it("does not retry other 4xx", () => {
    expect(isRetryable({ status: 400 })).toBe(false);
    expect(isRetryable({ status: 404 })).toBe(false);
  });

  it("does not retry programmer errors", () => {
    expect(isRetryable(new TypeError("bad"))).toBe(false);
    expect(isRetryable(new RangeError("bad"))).toBe(false);
  });

  it("retries unknown failures", () => {
    expect(isRetryable(new Error("connection reset"))).toBe(true);
  });
});

describe("withRetry", () => {
  const options = { ...DEFAULT_RETRY, sleep: noSleep, random: () => 0 };

  it("returns the first successful result without retrying", async () => {
    const operation = vi.fn().mockResolvedValue("ok");
    await expect(withRetry(operation, options)).resolves.toBe("ok");
    expect(operation).toHaveBeenCalledTimes(1);
  });

  it("retries transient failures and eventually succeeds", async () => {
    const operation = vi.fn().mockRejectedValueOnce({ status: 503 }).mockResolvedValue("recovered");
    await expect(withRetry(operation, options)).resolves.toBe("recovered");
    expect(operation).toHaveBeenCalledTimes(2);
  });

  it("gives up after the attempt budget", async () => {
    const operation = vi.fn().mockRejectedValue({ status: 500 });
    await expect(withRetry(operation, { ...options, attempts: 3 })).rejects.toEqual({
      status: 500,
    });
    expect(operation).toHaveBeenCalledTimes(3);
  });

  it("does not retry a non-retryable failure", async () => {
    const operation = vi.fn().mockRejectedValue({ status: 400 });
    await expect(withRetry(operation, options)).rejects.toEqual({ status: 400 });
    expect(operation).toHaveBeenCalledTimes(1);
  });

  it("rejects an attempt budget below 1", async () => {
    await expect(withRetry(async () => "x", { ...options, attempts: 0 })).rejects.toThrow(
      RangeError,
    );
  });
});
