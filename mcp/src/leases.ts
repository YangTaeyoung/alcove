// Lease tokens held by this server and the control client that attaches them.
import { ControlClient, type ControlReply } from "./control.js";

/** Remembers lease tokens per VM and adds `lease` to params of calls that name that VM. */
export class LeaseBook {
  private tokens = new Map<string, string>();

  set(vm: string, token: string): void {
    this.tokens.set(vm, token);
  }

  clear(vm: string): void {
    this.tokens.delete(vm);
  }

  get(vm: string): string | undefined {
    return this.tokens.get(vm);
  }

  entries(): Array<[string, string]> {
    return [...this.tokens.entries()];
  }

  /** Returns params with `lease` added when `name` has a stored token and the caller gave no lease. */
  apply(params: Record<string, unknown>): Record<string, unknown> {
    const name = params.name;
    if (typeof name !== "string" || params.lease !== undefined) return params;
    const token = this.tokens.get(name);
    return token === undefined ? params : { ...params, lease: token };
  }
}

/** A ControlClient whose calls carry the lease this session holds for the VM they name. */
export class LeasedControlClient extends ControlClient {
  readonly leases = new LeaseBook();

  override call(op: string, params: Record<string, unknown> = {}, timeoutMs?: number): Promise<ControlReply> {
    return super.call(op, this.leases.apply(params), timeoutMs);
  }

  /** Releases every held lease, ignoring failures. */
  async releaseAll(timeoutMs = 5000): Promise<void> {
    await Promise.all(
      this.leases.entries().map(async ([name, lease]) => {
        try {
          await super.call("vm.lease.release", { name, lease }, timeoutMs);
        } catch {
          /* best effort */
        }
        this.leases.clear(name);
      }),
    );
  }
}
