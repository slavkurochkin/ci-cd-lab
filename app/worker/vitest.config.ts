import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    coverage: {
      provider: "v8",
      include: ["src/**/*.ts"],
      exclude: ["src/index.ts"],
      reporter: ["text", "lcov"],
      // A floor, not a target.
      //
      // These are the numbers this suite already achieves. They exist to catch
      // a regression, not to tell anyone what "enough" is. Raise them when the
      // real number rises; never lower them to make a build pass.
      //
      // Read what they measure: whether a line executed. A test with no
      // assertions raises this number. The gate stops coverage falling
      // silently; it cannot tell you the tests are any good.
      thresholds: {
        statements: 90,
        branches: 85,
        functions: 75,
        lines: 90,
      },
    },
  },
});
