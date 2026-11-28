import { spawn } from "node:child_process";
import { access, constants, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import type { Status } from "./types.js";

export class RedlightError extends Error {
  readonly exitCode?: number;
  readonly stderr?: string;

  constructor(message: string, options: { exitCode?: number; stderr?: string } = {}) {
    super(message);
    this.name = "RedlightError";
    this.exitCode = options.exitCode;
    this.stderr = options.stderr;
  }
}

export type RedlightClientOptions = {
  executablePath?: string;
  environment?: NodeJS.ProcessEnv;
  timeoutMs?: number;
};

const defaultTimeoutMs = 8_000;

export class RedlightClient {
  private readonly executablePath?: string;
  private readonly environment: NodeJS.ProcessEnv;
  private readonly timeoutMs: number;

  constructor(options: RedlightClientOptions = {}) {
    this.executablePath = options.executablePath;
    this.environment = { ...process.env, ...options.environment };
    this.timeoutMs = options.timeoutMs ?? defaultTimeoutMs;
  }

  async command(args: string[]): Promise<Status> {
    return this.run([...args, "--json"]);
  }

  async status(): Promise<Status> {
    return this.run(["status", "--json"]);
  }

  async resolveExecutable(): Promise<string> {
    if (this.executablePath) {
      if (await isExecutable(this.executablePath)) return this.executablePath;
      throw new RedlightError(`Configured Redlight executable is not executable: ${this.executablePath}`);
    }

    const candidates = [
      this.environment.REDLIGHT_CLI_PATH,
      "/opt/homebrew/bin/redlight",
      "/usr/local/bin/redlight",
      "/Applications/Redlight.app/Contents/MacOS/Redlight",
      path.join(os.homedir(), "Applications/Redlight.app/Contents/MacOS/Redlight"),
    ].filter((candidate): candidate is string => Boolean(candidate));

    for (const candidate of candidates) {
      if (await isExecutable(candidate)) {
        return candidate;
      }
    }

    throw new RedlightError("Redlight CLI was not found. Install Redlight or configure REDLIGHT_CLI_PATH.");
  }

  private async run(args: string[]): Promise<Status> {
    const executable = await this.resolveExecutable();

    return new Promise<Status>((resolve, reject) => {
      const child = spawn(executable, args, {
        cwd: path.dirname(executable),
        env: this.environment,
        stdio: ["ignore", "pipe", "pipe"],
      });
      let stdout = "";
      let stderr = "";
      let settled = false;
      const timeout = setTimeout(() => {
        child.kill("SIGKILL");
        finishReject(new RedlightError("Redlight command timed out."));
      }, this.timeoutMs);

      const finishReject = (error: Error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        reject(error);
      };
      const finishResolve = (value: Status) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        resolve(value);
      };

      child.stdout.setEncoding("utf8");
      child.stderr.setEncoding("utf8");
      child.stdout.on("data", (chunk: string) => { stdout += chunk; });
      child.stderr.on("data", (chunk: string) => { stderr += chunk; });
      child.on("error", (error) => finishReject(new RedlightError(error.message)));
      child.on("close", (code) => {
        if (code !== 0) {
          let message = stderr.trim() || `Redlight command failed with exit code ${code ?? "unknown"}.`;
          try {
            const parsed = JSON.parse(stderr) as { error?: { message?: string } };
            message = parsed.error?.message ?? message;
          } catch {
            // Keep the plain-text CLI error.
          }
          finishReject(new RedlightError(message, { exitCode: code ?? undefined, stderr }));
          return;
        }

        try {
          const status = JSON.parse(stdout) as Status;
          if (typeof status.running !== "boolean") {
            throw new Error("Redlight returned a status without a running field.");
          }
          finishResolve(status);
        } catch (error) {
          finishReject(new RedlightError(`Redlight returned invalid JSON status: ${String(error)}`));
        }
      });
    });
  }
}

async function isExecutable(candidate: string): Promise<boolean> {
  try {
    await access(candidate, constants.X_OK);
    return (await stat(candidate)).isFile();
  } catch {
    return false;
  }
}
