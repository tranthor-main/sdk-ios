#!/usr/bin/env node
const { createMockServer } = require("./index.cjs");

async function main() {
  const args = process.argv.slice(2);
  if (args.length > 2 || (args.length && (args[0] !== "--port" || !/^\d+$/.test(args[1] ?? "")))) {
    throw new Error("Usage: node conformance/server/cli.cjs [--port 0..65535]");
  }
  const port = args.length ? Number(args[1]) : 0;
  if (port > 65535) throw new Error("Port must be between 0 and 65535");
  const mock = createMockServer();
  const address = await mock.start(port);
  process.stdout.write(`${JSON.stringify(address)}\n`);
  for (const signal of ["SIGINT", "SIGTERM"]) {
    process.once(signal, () => { void mock.close().then(() => process.exit(0)); });
  }
}

main().catch((error) => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
