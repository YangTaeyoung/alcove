// Element selector parameters shared by the ui tools and their control mapping.
import { z } from "zod";
import { ControlError } from "./control.js";

export const selectorParams = {
  ref: z.string().regex(/^e\d+$/).optional().describe("Element ref such as e12, from alcove_ui_tree or alcove_ui_find; takes the place of the other selector fields"),
  window: z.string().optional().describe("Window to search: a window id from alcove_list_windows, \"foreground\" (default), or a part of the title"),
  role: z.string().optional().describe("Control type without the ControlType. prefix, e.g. Button, Edit, MenuItem, ListItem; case-insensitive"),
  name: z.string().optional().describe("Exact accessible name"),
  name_contains: z.string().optional().describe("Part of the accessible name"),
  automation_id: z.string().optional().describe("AutomationId of the element"),
  index: z.number().int().min(0).optional().describe("0-based pick among several matches (default 0)"),
};

export interface SelectorArgs {
  ref?: string;
  window?: string;
  role?: string;
  name?: string;
  name_contains?: string;
  automation_id?: string;
  index?: number;
}

/** Control selector fields in camelCase; throws when neither `ref` nor a matching field is given. */
export function toControlSelector(a: SelectorArgs): Record<string, unknown> {
  if (a.ref === undefined && a.role === undefined && a.name === undefined && a.name_contains === undefined && a.automation_id === undefined) {
    throw new ControlError("pass ref or at least one of role, name, name_contains, automation_id");
  }
  const s: Record<string, unknown> = {};
  if (a.ref !== undefined) s.ref = a.ref;
  if (a.window !== undefined) s.window = a.window;
  if (a.role !== undefined) s.role = a.role;
  if (a.name !== undefined) s.name = a.name;
  if (a.name_contains !== undefined) s.nameContains = a.name_contains;
  if (a.automation_id !== undefined) s.automationId = a.automation_id;
  if (a.index !== undefined) s.index = a.index;
  return s;
}

const { name: _elementName, ...selectorWithoutName } = selectorParams;

/** Selector parameters of tools that also take the VM `name`: the element's exact name is `element_name`. */
export const elementSelectorParams = {
  ...selectorWithoutName,
  element_name: z.string().optional().describe("Exact accessible name of the element"),
};

/** Control params that select an element: `ref` at top level and the other fields in a nested `selector` object. */
export function toolSelector(a: Omit<SelectorArgs, "name"> & { element_name?: string }): Record<string, unknown> {
  const { element_name, ...rest } = a;
  const { ref, ...fields } = toControlSelector({ ...rest, ...(element_name !== undefined ? { name: element_name } : {}) });
  return { ...(ref !== undefined ? { ref } : {}), ...(Object.keys(fields).length ? { selector: fields } : {}) };
}
