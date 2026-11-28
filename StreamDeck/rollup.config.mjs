import commonjs from "@rollup/plugin-commonjs";
import nodeResolve from "@rollup/plugin-node-resolve";
import typescript from "@rollup/plugin-typescript";

export default {
  input: "src/plugin.ts",
  output: {
    file: "com.redlight.app.streamdeck.sdPlugin/bin/plugin.js",
    format: "es",
    sourcemap: true,
  },
  external: ["node:child_process", "node:fs", "node:os", "node:path"],
  plugins: [
    nodeResolve({ preferBuiltins: true }),
    commonjs(),
    typescript({ tsconfig: "./tsconfig.json" }),
  ],
};
