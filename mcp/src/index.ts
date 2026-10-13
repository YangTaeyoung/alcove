#!/usr/bin/env node
// alcove-mcp: an MCP server (stdio) exposing Alcove virtual machines to coding
// agents. Tools map onto the Alcove control protocol (docs/control-protocol.md).
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { LeasedControlClient } from "./leases.js";
import { registrar, selectedToolsets } from "./toolkit.js";
import { register as registerCore } from "./tools/core.js";
import { register as registerShell } from "./tools/shell.js";
import { register as registerFiles } from "./tools/files.js";
import { register as registerState } from "./tools/state.js";

const INSTRUCTIONS =
  "Alcove drives virtual machines. Text tools (alcove_exec, alcove_fs_*, alcove_process_*) are cheaper and more reliable than screenshots: prefer them whenever the guest tools are connected. " +
  "Run long commands such as builds and test suites with alcove_exec_start and follow them with alcove_exec_read instead of blocking in alcove_exec. " +
  "Move build output into the guest with alcove_sync_dir. " +
  "Take a snapshot with alcove_snapshot_create before risky changes and return to it with alcove_snapshot_restore; alcove_clone_vm gives a linked clone for parallel work; alcove_lease_acquire keeps other agents off a VM.";

let enabled;
try {
  enabled = selectedToolsets(process.env.ALCOVE_MCP_TOOLSETS);
} catch (e) {
  process.stderr.write(`alcove-mcp: ${(e as Error).message}\n`);
  process.exit(1);
}

const client = new LeasedControlClient();
const server = new McpServer({ name: "alcove-mcp-server", version: "0.2.0" }, { instructions: INSTRUCTIONS });
const reg = registrar(server, enabled);
registerCore(reg, client);
registerShell(reg, client);
registerFiles(reg, client);
registerState(reg, client);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  let closing = false;
  const shutdown = () => {
    if (closing) return;
    closing = true;
    client.releaseAll().finally(() => { client.close(); process.exit(0); });
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
  process.stdin.on("close", shutdown);
}

main().catch((e) => {
  process.stderr.write(`alcove-mcp fatal: ${String(e)}\n`);
  process.exit(1);
});
