// Writes test/json-cases.json: each row is [input JSON text, what
// JSON.stringify(JSON.parse(input), null, 2) returns].  Excalidraw saves with
// exactly that call, so the table is the oracle for esketch's writer.
import { writeFileSync } from "fs";
const inputs = [
  "0", "-0", "1", "1.0", "100.5", "1e3", "1.5E+3", "1e21", "1e20", "1e-7", "-1e-7",
  "0.000001", "0.0000012345", "123e-20", "2.5e-8", "0.1", "580.0000000000001",
  "-0.011448953630490633", "1722966992711", "4294967295", "9007199254740993",
  "123456789012345680000", "1.7976931348623157e308", "5e-324", "1.25", "-3",
  "\"plain\"", "\"a\\u00e9b\"", "\"tab\\there\"", "\"nl\\nx\"", "\"\\u0001\\u001f\"",
  "\"\\/\"", "\"q\\\"\\\\\"", "\"\\ud83d\\ude00\"", "\"\\u007f\"", "\"\\u2028\"",
  "\"\\b\\f\\r\"", "\"\u00e9 raw\"",
  "true", "false", "null", "[]", "{}", "[[]]", "[{}]", "[[0,0],[1,195]]",
  "{\"a\":{},\"b\":[],\"c\":null,\"d\":true,\"e\":false,\"f\":[1,{\"g\":\"h\"}]}",
];
const rows = inputs.map(i => [i, JSON.stringify(JSON.parse(i), null, 2)]);
writeFileSync(process.argv[2] ?? "test/json-cases.json", JSON.stringify(rows, null, 1) + "\n");
