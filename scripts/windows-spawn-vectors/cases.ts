// Test vectors for SwiftACP's port of acpx's Windows command resolution (#265): acpx's own
// `buildAgentSpawnCommand` and `resolveWindowsCommand`, run with `path.win32` and a fake Windows
// file system, and Node's `path.win32` itself for the path helpers they use; and for its terminals
// (#272), acpx's terminal launch and Node's own `spawn`. Run by generate.sh.
import { ChildProcess, spawn } from "node:child_process";
import nodePath from "node:path";
import { fakeFs } from "./fake-fs.ts";
import { buildAgentSpawnCommand, resolveInstalledExecutable, resolveWindowsCommand } from "./spawn-command-options.ts";
import { resolveClaudeCodeExecutable } from "./agent-command.ts";
import { buildTerminalFallbackSpawnCommand, buildTerminalSpawnOptions } from "./terminal-manager.ts";

// As on Windows: `resolveInstalledExecutable` asks `process.platform`, and a relative path is
// taken from `process.cwd()`.
Object.defineProperty(process, "platform", { value: "win32" });
process.cwd = () => "C:\\work";
// Read before the terminals' cases stand a Windows environment in for `process.env`.
const tag = process.env.ACPX_TAG ?? "v0.19.3";

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

type Claude = {
  name: string;
  env?: Record<string, string>;
  cwd?: string;
  files: string[];
  contents?: Record<string, string>;
};

// npm's shim for a JavaScript CLI, as it writes one for `claude`.
const npmCmdShim = (script: string) => [
  "@ECHO off", "GOTO start", ":find_dp0", "SET dp0=%~dp0", "EXIT /b", ":start", "SETLOCAL", "CALL :find_dp0",
  "", 'IF EXIST "%dp0%\\node.exe" (', '  SET "_prog=%dp0%\\node.exe"', ") ELSE (", '  SET "_prog=node"', ")", "",
  `endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\\${script}" %*`, "",
].join("\r\n");
const local = "C:\\Users\\me\\.local\\bin";
const claudes: Claude[] = [
  { name: "an exe on PATH", env: { ...base, Path: `${local};${npm}` }, files: [`${local}\\claude.exe`] },
  { name: "a cmd with an exe beside it", files: [`${npm}\\claude.cmd`, `${npm}\\claude.exe`] },
  {
    name: "npm's shim for the JavaScript CLI",
    files: [`${npm}\\claude.cmd`],
    contents: { [`${npm}\\claude.cmd`]: npmCmdShim("node_modules\\@anthropic-ai\\claude-code\\cli.js") },
  },
  {
    name: "a shim naming the native program",
    files: [`${npm}\\claude.cmd`, `${npm}\\node_modules\\@anthropic-ai\\claude-code\\bin\\claude.exe`],
    contents: { [`${npm}\\claude.cmd`]: npmCmdShim("node_modules\\@anthropic-ai\\claude-code\\bin\\claude.exe") },
  },
  {
    name: "%~dp0 and ..",
    files: [`${npm}\\claude.cmd`, "C:\\Users\\me\\AppData\\Roaming\\claude\\claude.exe"],
    contents: { [`${npm}\\claude.cmd`]: '@"%~dp0\\..\\claude\\claude.exe" %*' },
  },
  {
    name: "slashes and case",
    files: [`${npm}\\claude.bat`, `${npm}\\bin\\claude.exe`],
    contents: { [`${npm}\\claude.bat`]: '"%DP0%/bin//claude.exe" %*' },
  },
  {
    name: "space after the directory",
    files: [`${npm}\\claude.cmd`, `${npm}\\claude-native.exe`],
    contents: { [`${npm}\\claude.cmd`]: '"%dp0%  \\claude-native.exe" %*' },
  },
  {
    name: "the first program there wins",
    files: [`${npm}\\claude.cmd`, `${npm}\\b\\claude.exe`],
    contents: { [`${npm}\\claude.cmd`]: '"%dp0%" "%dp0%\\a\\claude.exe" "%dp0%\\b\\claude.exe" "%dp0%\\c\\claude.exe"' },
  },
  {
    name: "a quote left open on its line",
    files: [`${npm}\\claude.cmd`, `${npm}\\claude-native.exe`],
    contents: { [`${npm}\\claude.cmd`]: '"%dp0%\\claude-native.exe\r\n"%dp0%\\claude-native.exe"' },
  },
  {
    name: "a ps1 with an exe beside it",
    env: { ...base, PATHEXT: ".PS1" },
    files: [`${npm}\\claude.ps1`, `${npm}\\claude.exe`],
  },
  {
    name: "a ps1 naming nothing it can read",
    env: { ...base, PATHEXT: ".PS1" },
    files: [`${npm}\\claude.ps1`, `${npm}\\bin\\claude.exe`],
    contents: { [`${npm}\\claude.ps1`]: '& "$basedir/bin/claude.exe" $args' },
  },
  { name: "CLAUDE_CODE_EXECUTABLE named", env: { ...base, claude_code_executable: "D:\\claude.exe" }, files: [`${npm}\\claude.exe`] },
  { name: "CLAUDE_CODE_EXECUTABLE empty", env: { ...base, CLAUDE_CODE_EXECUTABLE: "" }, files: [`${npm}\\claude.exe`] },
  { name: "a relative PATH entry", env: { ...base, Path: "tools" }, cwd: "C:\\proj", files: ["C:\\proj\\tools\\claude.exe"] },
  { name: "nothing found", files: [] },
];
const claudeResults = claudes.map((claude) => {
  const env = claude.env ?? base;
  const cwd = claude.cwd ?? "C:\\work";
  fakeFs.set(claude.files, [], claude.contents ?? {});
  return {
    name: claude.name,
    env,
    cwd,
    files: claude.files,
    contents: claude.contents ?? {},
    processDirectory: process.cwd(),
    expected: resolveClaudeCodeExecutable("win32", env, cwd) ?? null,
  };
});

type Terminal = {
  name: string;
  command: string;
  args?: string[];
  parent?: Record<string, string>;
  request?: { name: string; value: string }[];
  cwd?: string;
  files?: string[];
  directories?: string[];
};

const tools = "C:\\tools";
const terminals: Terminal[] = [
  { name: "a program on PATH", command: "where", args: ["node"], files: [`${sys}\\where.exe`] },
  { name: "an npm shim, with arguments", command: "gemini", args: ["--version"], files: npmShim },
  { name: "an npm shim, no arguments", command: "gemini", files: npmShim },
  { name: "an empty argument", command: "gemini", args: ["", "x", ""], files: npmShim },
  {
    name: "arguments joined as they are",
    command: "gemini",
    args: ["-p", 'say "hi" & exit', "a\\b\\"],
    files: npmShim,
  },
  {
    name: "a bat on PATH",
    command: "build",
    args: ["release"],
    parent: { ...base, Path: `${tools};${sys}` },
    files: [`${tools}\\build.bat`],
  },
  {
    name: "a cmd by a relative path",
    command: ".\\scripts\\setup.cmd",
    args: ["x"],
    cwd: "C:\\proj",
    files: ["C:\\proj\\scripts\\setup.cmd"],
  },
  {
    name: "a cmd named in full, with a space",
    command: "C:\\Program Files\\tool\\run.cmd",
    args: ["a b"],
    files: ["C:\\Program Files\\tool\\run.cmd"],
  },
  { name: "a cmd that is not there", command: "missing.cmd", args: ["x"] },
  { name: "an upper-case extension", command: "C:\\tools\\RUN.CMD", files: ["C:\\tools\\RUN.CMD"] },
  {
    name: "an exe before a cmd",
    command: "gemini",
    args: ["x"],
    files: [`${npm}\\gemini.exe`, `${npm}\\gemini.cmd`],
  },
  { name: "no ComSpec", command: "gemini", args: ["x"], parent: { Path: base.Path }, files: npmShim },
  { name: "an empty ComSpec", command: "gemini", args: ["x"], parent: { ...base, ComSpec: "" }, files: npmShim },
  {
    name: "COMSPEC in upper case",
    command: "gemini",
    args: ["x"],
    parent: { Path: base.Path, COMSPEC: "D:\\cmd.exe" },
    files: npmShim,
  },
  {
    name: "another shell",
    command: "gemini",
    args: ["x"],
    parent: { ...base, ComSpec: "C:\\Program Files\\PowerShell\\7\\pwsh.exe" },
    files: npmShim,
  },
  {
    name: "a ComSpec with forward slashes",
    command: "gemini",
    args: ["x"],
    parent: { ...base, ComSpec: "C:/WINDOWS/system32/cmd.exe" },
    files: npmShim,
  },
  {
    name: "CMD.EXE in upper case",
    command: "gemini",
    args: ["x"],
    parent: { ...base, ComSpec: "C:\\WINDOWS\\SYSTEM32\\CMD.EXE" },
    files: npmShim,
  },
  { name: "a bare cmd", command: "gemini", args: ["x"], parent: { ...base, ComSpec: "cmd" }, files: npmShim },
  {
    name: "a ComSpec with a line break",
    command: "gemini",
    args: ["x"],
    parent: { ...base, ComSpec: "C:\\a\nb\\cmd.exe" },
    files: npmShim,
  },
  {
    name: "cmd.exe after a slash",
    command: "gemini",
    args: ["x"],
    parent: { ...base, ComSpec: "C:\\WINDOWS/cmd.exe" },
    files: npmShim,
  },
  {
    name: "the request's Path",
    command: "gemini",
    args: ["x"],
    parent: { ...base, Path: sys },
    request: [{ name: "Path", value: tools }],
    files: [`${tools}\\gemini.cmd`],
  },
  {
    name: "the request's PATH, not looked at beside the client's Path",
    command: "gemini",
    args: ["x"],
    parent: { ...base, Path: sys },
    request: [{ name: "PATH", value: tools }],
    files: [`${tools}\\gemini.cmd`],
  },
  {
    name: "the request's PATH, with none of the client's",
    command: "gemini",
    args: ["x"],
    parent: { ComSpec: base.ComSpec, PATHEXT: pathext },
    request: [{ name: "PATH", value: tools }],
    files: [`${tools}\\gemini.cmd`],
  },
  {
    name: "the request's first PATH",
    command: "gemini",
    args: ["x"],
    parent: { ComSpec: base.ComSpec, PATHEXT: pathext },
    request: [
      { name: "PATH", value: "C:\\a" },
      { name: "path", value: tools },
    ],
    files: [`${tools}\\gemini.cmd`],
  },
  {
    name: "the request's PATH set twice",
    command: "gemini",
    args: ["x"],
    parent: { ComSpec: base.ComSpec, PATHEXT: pathext },
    request: [
      { name: "PATH", value: "C:\\a" },
      { name: "path", value: "C:\\b" },
      { name: "PATH", value: tools },
    ],
    files: [`${tools}\\gemini.cmd`],
  },
  {
    name: "the request's PATHEXT",
    command: "gemini",
    args: ["x"],
    request: [{ name: "PATHEXT", value: ".EXE" }],
    files: npmShim,
  },
  // The fallback, for a command that was not found.
  { name: "a line", command: "echo hi" },
  { name: "a pipe", command: "dir|more" },
  { name: "an ampersand", command: "a&b" },
  { name: "a word", command: "nothere" },
  { name: "a backslash is no syntax", command: "C:\\nothere\\x" },
  { name: "a percent is none", command: "%COMSPEC%" },
  { name: "a caret is none", command: "a^b" },
  { name: "a carriage return", command: "x\r" },
  { name: "a tab", command: "echo\thi" },
  { name: "a no-break space", command: "echo\u00a0hi" },
  { name: "a line separator", command: "echo\u2028hi" },
  { name: "an ideographic space", command: "echo\u3000hi" },
  { name: "a zero-width space is none", command: "echo\u200bhi" },
  {
    name: "a path that is there",
    command: "C:\\Program Files\\app\\run.exe",
    files: ["C:\\Program Files\\app\\run.exe"],
  },
  { name: "a path that is not there", command: "C:\\Program Files\\app\\missing.exe" },
  { name: "a relative path that is there", command: "tools\\run me", cwd: "C:\\proj", files: ["C:\\proj\\tools\\run me"] },
  { name: "a relative path, forward slashes", command: "tools/run me", cwd: "C:\\proj", files: ["C:\\proj\\tools\\run me"] },
  { name: "a relative directory", command: "tools\\run me", cwd: "proj", files: ["C:\\work\\proj\\tools\\run me"] },
  { name: "a directory that is there", command: "C:\\my dir", directories: ["C:\\my dir"] },
];
// Node's `spawn`, up to the native one: the file and arguments it starts, after its shell.
let started: { file: string; args: string[]; windowsVerbatimArguments: boolean } | undefined;
ChildProcess.prototype.spawn = function (options) {
  started = options;
  return 0;
};
process.noDeprecation = true;
// A Windows `process.env`: a name found in any case.
const windowsEnv = (variables: Record<string, string>) =>
  new Proxy(variables, {
    get(target, key) {
      if (typeof key !== "string" || key in target) return Reflect.get(target, key);
      const name = Object.keys(target).find((entry) => entry.toUpperCase() === key.toUpperCase());
      return name === undefined ? undefined : target[name];
    },
  });
const terminalResults = terminals.map((terminal) => {
  const parent = terminal.parent ?? base;
  const cwd = terminal.cwd ?? "C:\\work";
  fakeFs.set(terminal.files ?? [], terminal.directories ?? []);
  process.env = windowsEnv({ ...parent });
  started = undefined;
  spawn(terminal.command, terminal.args ?? [], buildTerminalSpawnOptions(terminal.command, cwd, terminal.request, "win32"));
  if (!started) throw new Error(`nothing started for ${terminal.name}`);
  const fallback = buildTerminalFallbackSpawnCommand(terminal.command, cwd, "win32");
  return {
    name: terminal.name,
    command: terminal.command,
    ...(terminal.args ? { args: terminal.args } : {}),
    parent,
    request: terminal.request ?? [],
    cwd,
    files: terminal.files ?? [],
    directories: terminal.directories ?? [],
    processDirectory: process.cwd(),
    expected: {
      command: started.file,
      args: started.args.slice(1),
      windowsVerbatimArguments: started.windowsVerbatimArguments,
      fallback: fallback ? { command: fallback.command, args: fallback.args } : null,
    },
  };
});

const dirname = [
  "C:\\a\\b.cmd", "C:\\a\\", "C:\\a", "C:\\", "C:", "C:x", "\\\\srv\\sh\\x.cmd", "\\\\srv\\sh", "\\\\srv\\sh\\",
  "/a/b", "a", "", "\\", "a\\\\b\\\\", "C:\\a\\\\\\b", "\\\\srv", "C:a\\b",
];

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
  generatedBy: `acpx ${tag} src/spawn-command-options.ts and src/acp/terminal-manager.ts, path.win32, Node ${process.version}`,
  spawns: spawnResults,
  installed: installedResults,
  claudeExecutable: claudeResults,
  terminals: terminalResults,
  paths: {
    normalize: normalize.map((input) => ({ input, output: win.normalize(input) })),
    resolve: resolve.map(([cwd, input]) => ({ cwd, input, output: win.resolve(cwd, input) })),
    join: join.map(([a, b]) => ({ input: [a, b], output: win.join(a, b) })),
    isAbsolute: isAbsolute.map((input) => ({ input, output: win.isAbsolute(input) })),
    extname: extname.map((input) => ({ input, output: win.extname(input) })),
    dirname: dirname.map((input) => ({ input, output: win.dirname(input) })),
  },
}, null, 2));
