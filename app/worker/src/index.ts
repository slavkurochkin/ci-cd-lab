/** Entrypoint. Prints build identity, then works through WORK_ITEMS items and exits. */

import { withRetry } from "./retry.ts";
import { exitCodeFor, processItems } from "./work.ts";

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

async function main(): Promise<void> {
  // As PID 1 in a container, Node has no default action for SIGTERM: without
  // this handler the signal is ignored and the kubelet sends SIGKILL when the
  // grace period ends (32s to delete a pod, measured in Project 12).
  const stop = new AbortController();
  process.once("SIGTERM", () => {
    console.log("SIGTERM: finishing the current item, then stopping");
    stop.abort();
  });

  console.log(
    JSON.stringify({
      service: "lab-worker",
      version: process.env.npm_package_version ?? "0.1.0",
      gitSha: process.env.GIT_SHA ?? "unknown",
      environment: process.env.ENVIRONMENT ?? "local",
    }),
  );

  const result = await withRetry(async () => "ready");
  console.log(`worker ${result}`);

  const items = Number(process.env.WORK_ITEMS ?? "0");
  const itemMs = Number(process.env.WORK_ITEM_MS ?? "1000");
  const work = await processItems(items, () => sleep(itemMs), stop.signal);
  console.log(
    JSON.stringify({ itemsDone: work.done, itemsTotal: items, interrupted: work.interrupted }),
  );
  process.exitCode = exitCodeFor(work);
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});
