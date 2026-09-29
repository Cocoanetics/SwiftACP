// Records fast-wrap-ansi 0.2.2's wrapAnsi(text, columns, { hard: true, trim: false }) — as
// @clack/core calls it — for narrow and non-positive widths, as wrap-ansi.json:
//   node wrap-ansi.mjs <acpx>/node_modules/fast-wrap-ansi/lib/main.js > wrap-ansi.json
const { wrapAnsi } = await import(process.argv[2] ?? "fast-wrap-ansi");
const texts = [
  "abc", "abc def", "abcdef ghi", " lead", "a  b", "\u001b[36mcyan text\u001b[39m", "\u001b[2m(hint)\u001b[22m x",
  "日本語 text", "é café", "", "x\ny", "│  Agent targets",
];
const cases = [];
for (const text of texts) {
  for (const columns of [-3, -1, 0, 1, 2, 3]) {
    cases.push({ text, columns, wrapped: wrapAnsi(text, columns, { hard: true, trim: false }) });
  }
}
console.log(JSON.stringify({ cases }, null, 1));
