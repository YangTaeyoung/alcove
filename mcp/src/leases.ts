// Lease tokens held by this server and the control client that attaches them.
import { ControlClient, ControlError, type ControlReply } from "./control.js";

/** Whether a control error says that a lease token is not the one that holds the VM. */
export function isLeaseLost(message: string): boolean {
  return /^lease token does not match; only the holder can release '/.test(message) || /^VM '.*' is leased by /.test(message);
}

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

/**
 * A ControlClient whose calls carry the lease this session holds for the VM they name.
 * A call that fails with a lease error (`isLeaseLost`) removes the stored lease of the VM it names,
 * unless the caller passed its own `lease`.
 */
export class LeasedControlClient extends ControlClient {
  readonly leases = new LeaseBook();

  override async call(op: string, params: Record<string, unknown> = {}, timeoutMs?: number): Promise<ControlReply> {
    try {
      return await super.call(op, this.leases.apply(params), timeoutMs);
    } catch (e) {
      if (e instanceof ControlError && typeof params.name === "string" && params.lease === undefined && isLeaseLost(e.message)) {
        this.leases.clear(params.name);
      }
      throw e;
    }
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
