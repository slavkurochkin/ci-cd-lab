/** Entrypoint. Prints build identity, then exits -- the labs care about the image, not the runtime. */

import { withRetry } from "./retry.ts";

async function main(): Promise<void> {
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
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});
