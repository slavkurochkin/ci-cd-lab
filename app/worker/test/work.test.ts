import { describe, expect, it } from "vitest";

import { exitCodeFor, processItems } from "../src/work.ts";

describe("processItems", () => {
  it("processes every item when not stopped", async () => {
    const seen: number[] = [];
    const result = await processItems(
      3,
      async (i) => void seen.push(i),
      new AbortController().signal,
    );
    expect(seen).toEqual([0, 1, 2]);
    expect(result).toEqual({ done: 3, interrupted: false });
  });

  it("finishes the item in hand, then stops", async () => {
    const stop = new AbortController();
    const seen: number[] = [];
    const result = await processItems(
      5,
      async (i) => {
        seen.push(i);
        if (i === 1) stop.abort(); // SIGTERM arrives during item 1
      },
      stop.signal,
    );
    expect(seen).toEqual([0, 1]);
    expect(result).toEqual({ done: 2, interrupted: true });
  });

  it("starts nothing if already stopped", async () => {
    const stop = new AbortController();
    stop.abort();
    const result = await processItems(3, async () => {}, stop.signal);
    expect(result).toEqual({ done: 0, interrupted: true });
  });

  it("is not interrupted by a stop after the last item", async () => {
    const stop = new AbortController();
    const result = await processItems(1, async () => stop.abort(), stop.signal);
    expect(result).toEqual({ done: 1, interrupted: false });
  });
});

describe("exitCodeFor", () => {
  it("exits 0 only for a finished batch", () => {
    expect(exitCodeFor({ done: 3, interrupted: false })).toBe(0);
    expect(exitCodeFor({ done: 1, interrupted: true })).toBe(143);
  });
});
