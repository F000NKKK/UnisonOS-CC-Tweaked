// Conversion between protobuf LuaValue/LuaTable and плоского JS-значения.
// Агент шлёт результаты как уже плоский JSON (Lua ↔ JSON через json.lua),
// поэтому мы реально просто оборачиваем его в LuaValue для gRPC-ответа и
// разворачиваем при получении — без отдельного encoder для каждого типа.

export type LuaPlain =
  | null
  | boolean
  | number
  | string
  | Uint8Array
  | LuaPlain[]
  | { [k: string]: LuaPlain };

export interface LuaValuePb {
  nil_value?: boolean;
  bool_value?: boolean;
  number_value?: number;
  int_value?: string | number;
  string_value?: string;
  bytes_value?: Buffer;
  table_value?: LuaTablePb;
}

export interface LuaTablePb {
  array_items: LuaValuePb[];
  map_items: Record<string, LuaValuePb>;
}

export function plainToLuaValue(v: LuaPlain): LuaValuePb {
  if (v === null || v === undefined) return { nil_value: true };
  if (typeof v === "boolean") return { bool_value: v };
  if (typeof v === "number") {
    return Number.isInteger(v) ? { int_value: v } : { number_value: v };
  }
  if (typeof v === "string") return { string_value: v };
  if (v instanceof Uint8Array) return { bytes_value: Buffer.from(v) };
  if (Array.isArray(v)) {
    return {
      table_value: {
        array_items: v.map(plainToLuaValue),
        map_items: {},
      },
    };
  }
  // object
  const map: Record<string, LuaValuePb> = {};
  for (const [k, val] of Object.entries(v)) {
    map[k] = plainToLuaValue(val as LuaPlain);
  }
  return { table_value: { array_items: [], map_items: map } };
}

export function luaValueToPlain(pb: LuaValuePb | undefined): LuaPlain {
  if (!pb) return null;
  if (pb.nil_value) return null;
  if (pb.bool_value !== undefined) return pb.bool_value;
  if (pb.number_value !== undefined) return pb.number_value;
  if (pb.int_value !== undefined) return Number(pb.int_value);
  if (pb.string_value !== undefined) return pb.string_value;
  if (pb.bytes_value !== undefined) return new Uint8Array(pb.bytes_value);
  if (pb.table_value) {
    const t = pb.table_value;
    const hasArr = (t.array_items?.length ?? 0) > 0;
    const hasMap = Object.keys(t.map_items ?? {}).length > 0;
    if (hasMap) {
      const out: Record<string, LuaPlain> = {};
      if (hasArr) {
        // Lua array part: serialise as 1-based indexed keys to preserve mixed.
        t.array_items.forEach((v, i) => { out[String(i + 1)] = luaValueToPlain(v); });
      }
      for (const [k, v] of Object.entries(t.map_items)) out[k] = luaValueToPlain(v);
      return out;
    }
    return (t.array_items ?? []).map(luaValueToPlain);
  }
  return null;
}

// LuaResult builder: универсальный (ok, value | error) ответ для gRPC.
export function luaOk(value: LuaPlain) {
  return { ok: true, value: plainToLuaValue(value), error: "" };
}
export function luaErr(error: string) {
  return { ok: false, value: { nil_value: true }, error };
}
export function luaTuple(values: LuaPlain[], err?: string) {
  if (err) return { ok: false, value: { nil_value: true }, extra: [], error: err };
  const [first, ...rest] = values;
  return {
    ok: true,
    value: plainToLuaValue(first ?? null),
    extra: rest.map(plainToLuaValue),
    error: "",
  };
}
