#!/usr/bin/env node
// alcove-mcp: an MCP server (stdio) exposing Alcove virtual machines to coding
// agents. Tools map onto the Alcove control protocol (docs/control-protocol.md).
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { LeasedControlClient } from "./leases.js";
import { registrar, selectedToolsets, serverInstructions } from "./toolkit.js";
import { register as registerCore } from "./tools/core.js";
import { register as registerActions } from "./tools/actions.js";
import { register as registerShell } from "./tools/shell.js";
import { register as registerFiles } from "./tools/files.js";
import { register as registerState } from "./tools/state.js";
import { register as registerUi } from "./tools/ui.js";
import { register as registerEvidence } from "./tools/evidence.js";
import { register as registerReplay } from "./tools/replay.js";
import { register as registerHttp } from "./tools/http.js";

let enabled;
try {
  enabled = selectedToolsets(process.env.ALCOVE_MCP_TOOLSETS);
} catch (e) {
  process.stderr.write(`alcove-mcp: ${(e as Error).message}\n`);
  process.exit(1);
}

const client = new LeasedControlClient();
const server = new McpServer({ name: "alcove-mcp-server", version: "0.2.0" }, { instructions: serverInstructions(enabled) });
const reg = registrar(server, enabled);
registerCore(reg, client);
registerActions(reg, client);
registerShell(reg, client);
registerFiles(reg, client);
registerState(reg, client);
registerUi(reg, client);
registerEvidence(reg, client);
registerReplay(reg, client);
registerHttp(reg, client);

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
