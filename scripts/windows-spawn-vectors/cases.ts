// Test vectors for SwiftACP's port of acpx's Windows command resolution (#265): acpx's own
// `buildAgentSpawnCommand` and `resolveWindowsCommand`, run with `path.win32` and a fake Windows
// file system, and Node's `path.win32` itself for the path helpers they use. Run by generate.sh.
import nodePath from "node:path";
import { fakeFs } from "./fake-fs.ts";
import { buildAgentSpawnCommand, resolveInstalledExecutable, resolveWindowsCommand } from "./spawn-command-options.ts";

// As on Windows: `resolveInstalledExecutable` asks `process.platform`, and a relative path is
// taken from `process.cwd()`.
Object.defineProperty(process, "platform", { value: "win32" });
process.cwd = () => "C:\\work";

const win = nodePath.win32;
const npm = "C:\\Users\\me\\AppData\\Roaming\\npm";
const sys = "C:\\WINDOWS\\system32";
const pathext = ".COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC";
const base = { Path: `${npm};${sys}`, ComSpec: `${sys}\\cmd.exe`, PATHEXT: pathext };
const npmShim = [`${npm}\\gemini`, `${npm}\\gemini.cmd`, `${npm}\\gemini.ps1`];

type Spawn = {
  name: string;
  command: string;
  args?: string[];
  env?: Record<string, string>;
  cwd?: string;
  files?: string[];
};

const spawns: Spawn[] = [
  { name: "an npm shim on PATH", command: "gemini", files: npmShim },
  { name: "no ComSpec", command: "gemini", env: { Path: base.Path }, files: npmShim },
  { name: "upper-case keys", command: "gemini", env: { PATH: base.Path, COMSPEC: "D:\\cmd.exe" }, files: npmShim },
  {
    name: "an exe before a cmd in one directory",
    command: "gemini",
    env: { ...base, PATHEXT: ".EXE;.CMD" },
    files: [`${npm}\\gemini.exe`, `${npm}\\gemini.cmd`],
  },
  {
    name: "a cmd before an exe by PATHEXT's order",
    command: "gemini",
    env: { ...base, PATHEXT: ".CMD;.EXE" },
    files: [`${npm}\\gemini.exe`, `${npm}\\gemini.cmd`],
  },
  {
    name: "the first PATH directory wins",
    command: "gemini",
    env: { ...base, Path: `${npm};C:\\tools` },
    files: [`${npm}\\gemini.cmd`, "C:\\tools\\gemini.exe"],
  },
  {
    name: "the first PATH directory wins, an exe",
    command: "gemini",
    env: { ...base, Path: `C:\\tools;${npm}` },
    files: [`${npm}\\gemini.cmd`, "C:\\tools\\gemini.exe"],
  },
  {
    name: "a space in the path",
    command: "gemini",
    env: { ...base, Path: "C:\\Program Files\\nodejs" },
    files: ["C:\\Program Files\\nodejs\\gemini.cmd"],
  },
  {
    name: "parentheses in the path",
    command: "gemini",
    env: { ...base, Path: "C:\\Program Files (x86)\\gem" },
    files: ["C:\\Program Files (x86)\\gem\\gemini.cmd"],
  },
  {
    name: "a relative node_modules shim",
    command: "node_modules\\.bin\\gemini",
    cwd: "C:\\proj",
    files: ["C:\\proj\\node_modules\\.bin\\gemini.cmd"],
  },
  {
    name: "a relative node_modules shim, forward slashes",
    command: "./node_modules/.bin/gemini",
    cwd: "C:\\proj",
    files: ["C:\\proj\\node_modules\\.bin\\gemini.cmd"],
  },
  { name: "a name with its extension", command: "gemini.cmd", files: npmShim },
  { name: "an absolute cmd", command: "C:\\tools\\gemini.cmd", files: ["C:\\tools\\gemini.cmd"] },
  { name: "an absolute cmd that is missing", command: "C:\\tools\\missing.cmd", files: [] },
  { name: "nothing found", command: "copilot", files: [] },
  { name: "a bat", command: "gemini", files: [`${npm}\\gemini.bat`] },
  {
    name: "an upper-case extension",
    command: "C:\\Tools\\GEMINI.CMD",
    files: ["c:\\tools\\gemini.cmd"],
  },
  {
    name: "padded and empty PATH entries",
    command: "gemini",
    env: { ...base, Path: ` ;C:\\empty; ${npm} ;` },
    files: [`${npm}\\gemini.cmd`],
  },
  {
    name: "a relative PATH entry",
    command: "gemini",
    env: { ...base, Path: "tools;C:\\x" },
    cwd: "C:\\proj",
    files: ["C:\\proj\\tools\\gemini.cmd"],
  },
  { name: "no PATH", command: "gemini", env: { ComSpec: base.ComSpec }, files: npmShim },
  { name: "a ps1 only", command: "gemini", files: [`${npm}\\gemini.ps1`] },
  { name: "a path without an extension", command: "C:\\tools\\gemini", files: ["C:\\tools\\gemini.cmd"] },
  { name: "an absolute path, forward slashes", command: "C:/tools/gemini.cmd", files: ["C:\\tools\\gemini.cmd"] },
  { name: "a UNC path", command: "\\\\server\\share\\gemini.cmd", files: ["\\\\server\\share\\gemini.cmd"] },
  { name: "a trailing dot", command: "gemini.", files: [`${npm}\\gemini.cmd`] },
];

const escapes = [
  ["--version"], ["--help"], [""], ["a b"], ["a&b"], ["a|b"], ["<in>"], [">out"], ["%PATH%"],
  ["!x!"], ["a^b"], ['say "hi"'], ["trail\\"], ['back\\"slash'], ["C:\\dir with space\\"],
  ["semi;colon"], ["comma,x"], ["star*"], ["q?"], ["(paren)"], ["[br]"], ["`tick`"], ["tab\tx"],
  ["new\nline"], ["unicode é ✓"], ["--flag", "value with space", "x&y"], [],
  // Runs of backslashes before a quote and at the end: acpx doubles only the last of each.
  ['a\\\\"b'], ['a\\\\\\"b'], ["t\\\\"], ["t\\\\\\"], ["x\\\\\\y"], ["\\\\"], ['\\"'],
];
for (const args of escapes) {
  const label = JSON.stringify(args);
  spawns.push({ name: `escaped ${label}`, command: "C:\\npm\\tool.cmd", args, files: ["C:\\npm\\tool.cmd"] });
  spawns.push({
    name: `escaped for a shim ${label}`,
    command: "C:\\proj\\node_modules\\.bin\\tool.cmd",
    args,
    files: ["C:\\proj\\node_modules\\.bin\\tool.cmd"],
  });
}
spawns.push({ name: "escaped, meta in the path", command: "C:\\a&b\\x^y\\tool.cmd", args: ["--help"], files: [] });

const spawnResults = spawns.map((spawn) => {
  const args = spawn.args ?? ["--version"];
  const env = spawn.env ?? base;
  const cwd = spawn.cwd ?? "C:\\work";
  const files = spawn.files ?? [];
  fakeFs.set(files);
  return {
    name: spawn.name,
    command: spawn.command,
    args,
    env,
    cwd,
    files,
    resolved: resolveWindowsCommand(spawn.command, env, cwd) ?? null,
    expected: buildAgentSpawnCommand(spawn.command, args, "win32", env, cwd),
  };
});

type Installed = {
  name: string;
  command: string;
  env?: Record<string, string>;
  files?: string[];
  directories?: string[];
};

// `resolveInstalledExecutable`: `process.env`, with no directory for a relative path, then made
// absolute against `process.cwd()`.
const installs: Installed[] = [
  { name: "an npm shim on PATH", command: "gemini", files: npmShim },
  { name: "an exe on PATH", command: "codex", env: { ...base, Path: `${npm};C:\\tools` }, files: ["C:\\tools\\codex.exe"] },
  { name: "a directory named like a command", command: "codex", files: [], directories: [`${npm}\\codex.exe`] },
  { name: "a relative PATH entry", command: "codex", env: { ...base, Path: "bin" }, files: ["C:\\work\\bin\\codex.exe"] },
  { name: "a relative command", command: "tools\\codex", files: ["C:\\work\\tools\\codex.exe"] },
  { name: "an absolute command", command: "C:/tools/codex.exe", files: ["C:\\tools\\codex.exe"] },
  { name: "nothing found", command: "codex", files: [] },
  { name: "no PATH", command: "gemini", env: { ComSpec: base.ComSpec }, files: npmShim },
];
const installedResults = installs.map((install) => {
  const env = install.env ?? base;
  fakeFs.set(install.files ?? [], install.directories ?? []);
  process.env = env;
  return {
    name: install.name,
    command: install.command,
    env,
    files: install.files ?? [],
    directories: install.directories ?? [],
    processDirectory: process.cwd(),
    expected: resolveInstalledExecutable(install.command) ?? null,
  };
});

const normalize = [
  "C:\\a\\b", "C:/a/b", "C:\\a\\..\\b", "C:\\a\\.\\b\\", "C:\\..", "C:", "C:a\\b", "\\a\\b",
  "//server/share/x", "\\\\server\\share", "a\\b\\..\\..\\..", ".\\a", "", "a//b", "C:\\a\\\\b",
  "C:\\", "/", "a", "..\\..\\x", "C:\\a\\b\\..\\..\\..\\c", "\\\\server\\share\\a\\..\\..",
  // Node's edges: device names, colons that could make a path absolute, device namespaces.
  "ab:c", "x\\C:", ":x", "1:\\a", "CON:x", "NUL", "CONx", "COM1:", "con:", "lpt\u00b9:a", "a\\b:",
  "\\\\.\\COM1:x", "\\\\?\\C:\\a\\..\\b", "\\\\.\\pipe\\x", "\\\\server", "\\\\server\\", "C:..\\x",
  "./c:", "a/b\\c/", "\\\\?\\COM1:", "C:\\a:b",
];
const resolve = [
  ["C:\\work", "a\\b"], ["C:\\work", "..\\x"], ["C:\\work", "\\root\\x"], ["C:\\work", "D:\\x"],
  ["C:\\work", "C:x"], ["C:\\work", "//server/share/x"], ["C:\\work\\", "."], ["\\\\srv\\sh\\dir", "x"],
  ["C:\\work", "C:\\npm\\gemini.cmd"], ["C:/work", "./node_modules/.bin/gemini.cmd"], ["C:\\work", ""],
  ["C:\\work", "x\\"], ["c:\\work", "C:x"],
  ["C:\\work", "\\\\.\\pipe\\x"], ["C:\\work", "\\\\server"], ["\\\\srv\\sh", "\\x"], ["C:\\work", "a\\..\\..\\.."],
  ["C:\\work", "\\\\?\\D:\\x"], ["C:\\", ".."],
];
const join = [
  ["C:\\npm", "gemini.cmd"], ["C:\\npm\\", "gemini.cmd"], ["C:/npm/", "gemini.cmd"], ["tools", "gemini.cmd"],
  ["\\\\server\\share", "x.cmd"], ["//server", "share"], ["", "x"], [".", "x"], ["C:", "x"],
  ["C:\\a\\..\\b", "x"], ["///x", "y"], ["C:\\npm", "..\\x.cmd"],
  ["C:\\a", "CON:x"], ["C:/a", "b/NUL:"], ["\\\\", "x"], ["//", "server/share"],
];
const isAbsolute = ["C:\\x", "C:/x", "C:x", "\\x", "/x", "x", "", "\\\\srv\\sh", "C:"];
const extname = [
  "gemini", "gemini.cmd", "gemini.", ".bashrc", "C:\\a.b\\gemini", "C:\\a\\gemini.tar.gz", "a/b.CMD",
  "..", "C:\\npm\\.bin", "C:\\npm\\x.", "a.b\\", "C:\\x\\.cmd", "..cmd",
];

console.log(JSON.stringify({
  generatedBy: `acpx ${process.env.ACPX_TAG ?? "v0.19.3"} src/spawn-command-options.ts, path.win32, Node ${process.version}`,
  spawns: spawnResults,
  installed: installedResults,
  paths: {
    normalize: normalize.map((input) => ({ input, output: win.normalize(input) })),
    resolve: resolve.map(([cwd, input]) => ({ cwd, input, output: win.resolve(cwd, input) })),
    join: join.map(([a, b]) => ({ input: [a, b], output: win.join(a, b) })),
    isAbsolute: isAbsolute.map((input) => ({ input, output: win.isAbsolute(input) })),
    extname: extname.map((input) => ({ input, output: win.extname(input) })),
  },
}, null, 2));
