// Records how Node's readline (`emitKeypressEvents`) reads each input, written as one chunk:
// what it passes as the typed text, the key's name and its whole sequence.
import { PassThrough } from "node:stream";
import readline from "node:readline";
const text = (s) => [...Buffer.from(s, "utf8")];
const inputs = [
  ..."aA5kjhliyYn\r\n\t\b\x7f .".split("").map(text), text("é"), text("😀"),
  ...["\x00", "\x01", "\x03", "\x0b", "\x0c", "\x1a", "\x1c"].map(text),
  ...["\x1b", "\x1b\x1b", "\x1bx", "\x1bA", "\x1bk", "\x1b\r", "\x1b ", "\x1b\x01", "\x1b\x03", "\x1b\x7f", "\x1bé"].map(text),
  ...["[A", "[B", "[C", "[D", "OA", "OD", "[a", "[d", "Oa", "Od", "[1;5A", "[1;2B", "[5C", "O5D", "[5a", "[1;10A",
    "[[A", "[200~", "[3~", "[Z", "[é", "[12;5~", "[123;5A", "[;A", "[1234~", "[12;A"].map((s) => text("\x1b" + s)),
  ...["\x1b\x1b[A", "\x1b\x1bOB", "\x1b\x1bx", "jjk\r", "\x1b[B\x1b[B ", "a\x1b", "y\x1bn"].map(text),
  [0xff], [0xc3, 0x78], [0xe2, 0x82, 0x78], [0x80], [0x80, 0x61], [0xc0, 0x80], [0xed, 0xa0, 0x80],
  [0xf4, 0x90, 0x80, 0x80], [0x1b, 0xff], [0x1b, 0x5b, 0xff], [0xe2, 0x1b], [0xc3, 0x0d],
  [0xc3], [0xe2, 0x82], text("\x1b["), text("\x1b[1;"), text("\x1bO"),
];
const cases = [];
for (const input of inputs) {
  const stream = new PassThrough();
  const keys = [];
  readline.emitKeypressEvents(stream, { escapeCodeTimeout: 50 });
  stream.on("keypress", (char, key) => keys.push([char ?? null, key.name ?? null, key.sequence]));
  stream.write(Buffer.from(input));
  await new Promise((resolve) => setTimeout(resolve, 120));
  cases.push({ input, keys });
}
console.log(JSON.stringify({ node: process.version, cases }, null, 1));
