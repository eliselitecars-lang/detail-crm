import { assertEquals, assertThrows } from "@std/assert";
import {
  escapeHtml,
  placeholdersIn,
  plainNumberText,
  renderTemplate,
  textToHtml,
} from "./templates.ts";

// Parity cases with SQL render_template(body, vars jsonb). Keep in sync with
// the SQL test suite (same inputs, same outputs).
const PARITY: Array<[string, Record<string, string | number | boolean | null>, string]> = [
  ["Hi {{customer_first_name}}!", { customer_first_name: "Ana" }, "Hi Ana!"],
  ["Hi {{ customer_first_name }}!", { customer_first_name: "Ana" }, "Hi Ana!"],
  ["Hi {{\tname\t}}", { name: "Tab" }, "Hi Tab"],
  ["Unknown: [{{nope}}]", {}, "Unknown: []"],
  ["Null: [{{v}}]", { v: null }, "Null: []"],
  ["{{a}}{{a}}{{b}}", { a: "x", b: "y" }, "xxy"],
  ["Case {{Name}} {{name}}", { name: "lower" }, "Case  lower"],
  ["Num {{n}} bool {{b}}", { n: 42, b: true }, "Num 42 bool true"],
  ["No recursion {{a}}", { a: "{{b}}", b: "B" }, "No recursion {{b}}"],
  ["Malformed {{ a b }} {a} {{}} {{1x}}", { a: "A" }, "Malformed {{ a b }} {a} {{}} {{1x}}"],
  ["Newline in braces {{\na}}", { a: "A" }, "Newline in braces {{\na}}"],
  ["Triple {{{a}}}", { a: "A" }, "Triple {A}"],
  ["Special $& $1 chars {{a}}", { a: "$& and $1" }, "Special $& $1 chars $& and $1"],
  ["Unicode {{a}}", { a: "Señor \u{1F697}" }, "Unicode Señor \u{1F697}"],
  ["", { a: "x" }, ""],
];

Deno.test("templates: SQL parity cases", () => {
  for (const [template, vars, expected] of PARITY) {
    assertEquals(renderTemplate(template, vars), expected, template);
  }
});

// Numbers: expected text is what Postgres 16 prints for
// (JSON.stringify({x}))::jsonb -> 'x' (jsonb numbers are numeric, whose text
// output never uses exponent notation). Verified against a live cluster.
const NUMBER_TEXT: Array<[number, string]> = [
  [0, "0"],
  [-0, "0"],
  [42, "42"],
  [-1, "-1"],
  [1.5, "1.5"],
  [0.1 + 0.2, "0.30000000000000004"],
  [0.000001, "0.000001"],
  [1e-7, "0.0000001"],
  [1.5e-7, "0.00000015"],
  [-1.5e-7, "-0.00000015"],
  [9.99e-10, "0.000000000999"],
  [1e20, "100000000000000000000"],
  [1e21, "1000000000000000000000"],
  [1.5e21, "1500000000000000000000"],
  [-1.2345e25, "-12345000000000000000000000"],
  [2 ** 53, "9007199254740992"],
  [1 / 3, "0.3333333333333333"],
  [5e-324, `0.${"0".repeat(323)}5`],
  [1.7976931348623157e308, `17976931348623157${"0".repeat(292)}`],
];

Deno.test("templates: numbers render exactly like SQL render_template (no exponent form)", () => {
  for (const [value, expected] of NUMBER_TEXT) {
    assertEquals(plainNumberText(value), expected, String(value));
    assertEquals(renderTemplate("[{{x}}]", { x: value }), `[${expected}]`, String(value));
  }
  assertThrows(() => plainNumberText(Number.POSITIVE_INFINITY), RangeError);
});

Deno.test("templates: prototype keys are not treated as vars", () => {
  assertEquals(renderTemplate("[{{constructor}}][{{toString}}]", {}), "[][]");
});

Deno.test("templates: non-scalar or non-finite values are rejected", () => {
  assertThrows(() => renderTemplate("{{a}}", { a: Number.NaN }), TypeError);
  // deno-lint-ignore no-explicit-any
  assertThrows(() => renderTemplate("{{a}}", { a: { nested: true } as any }), TypeError);
});

Deno.test("templates: placeholdersIn lists distinct names in order", () => {
  assertEquals(placeholdersIn("{{b}} {{ a }} {{b}} {{ bad name }}"), ["b", "a"]);
});

Deno.test("templates: escapeHtml and textToHtml", () => {
  assertEquals(
    escapeHtml(`<a href="x">'&'</a>`),
    "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;",
  );
  assertEquals(
    textToHtml("Hi <Ana>,\r\nsee https://app.example.com/i/tok?x=1&y=2.\n\nThanks"),
    '<p>Hi &lt;Ana&gt;,<br>see <a href="https://app.example.com/i/tok?x=1&amp;y=2">https://app.example.com/i/tok?x=1&amp;y=2</a>.</p>\n<p>Thanks</p>',
  );
  assertEquals(textToHtml("  \n "), "");
});
