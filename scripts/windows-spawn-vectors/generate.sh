#!/bin/sh
# Regenerates Tests/SwiftACPTests/Fixtures/acpx-windows-spawn.json from acpx's own Windows command
# resolution (src/spawn-command-options.ts) and terminal launch (src/acp/terminal-manager.ts), run
# with Node's path.win32 and a fake Windows file system (#265, #272).
#   ACPX_CHECKOUT  an acpx clone (required)
#   ACPX_TAG       the tag to take the resolution from (default: v0.19.3)
#   NODE           the node to run it with; 23.6 or later runs the TypeScript as it is
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
: "${ACPX_CHECKOUT:?set ACPX_CHECKOUT to an acpx clone}"
ACPX_TAG=${ACPX_TAG:-v0.19.3}
export ACPX_TAG
work=$(mktemp -d "${TMPDIR:-/tmp}/windows-spawn-vectors.XXXXXX")
trap 'rm -rf "$work"' EXIT
git -C "$ACPX_CHECKOUT" show "$ACPX_TAG:src/spawn-command-options.ts" \
    | sed -e 's#^import fs from "node:fs";#import { fakeFs as fs } from "./fake-fs.ts";#' \
          -e 's#^import path from "node:path";#import nodePath from "node:path"; const path = nodePath.win32;#' \
    > "$work/spawn-command-options.ts"
grep -q 'nodePath.win32' "$work/spawn-command-options.ts"
grep -q 'fakeFs as fs' "$work/spawn-command-options.ts"
# resolveClaudeCodeExecutable, from agent-command.ts, with the resolution above.
git -C "$ACPX_CHECKOUT" show "$ACPX_TAG:src/acp/agent-command.ts" \
    | awk '/^export function resolveClaudeCodeExecutable/,/^}/' \
    | sed -e '1i\
import { readWindowsEnvValue, resolveWindowsExecutablePath } from "./spawn-command-options.ts";' \
    > "$work/agent-command.ts"
grep -q 'resolveWindowsExecutablePath("claude"' "$work/agent-command.ts"
# A terminal's launch, from terminal-manager.ts: its spawn options, with the resolution above, and
# its shell fallback, with path.win32 and the fake file system (#272).
git -C "$ACPX_CHECKOUT" show "$ACPX_TAG:src/acp/terminal-manager.ts" \
    | awk '/^function toEnvObject/,/^}/
           /^export function buildTerminalSpawnOptions/,/^}/
           /^function buildTerminalFallbackSpawnCommand/,/^}/
           /^function hasShellSyntax/,/^}/
           /^function hasWindowsShellSyntax/,/^}/
           /^function commandPathExists/,/^}/' \
    | sed -e 's#^function buildTerminalFallbackSpawnCommand#export function buildTerminalFallbackSpawnCommand#' \
          -e '1i\
import nodePath from "node:path"; const path = nodePath.win32;\
import { fakeFs as fs } from "./fake-fs.ts";\
import { buildSpawnCommandOptions, buildTerminalShellSpawnCommand } from "./spawn-command-options.ts";' \
    > "$work/terminal-manager.ts"
for name in 'export function buildTerminalSpawnOptions' 'function toEnvObject' \
    'export function buildTerminalFallbackSpawnCommand' 'function hasWindowsShellSyntax' 'function commandPathExists'; do
    grep -q "^$name" "$work/terminal-manager.ts"
done
cp "$here/fake-fs.ts" "$here/cases.ts" "$work/"
"${NODE:-node}" "$work/cases.ts" > "$repo/Tests/SwiftACPTests/Fixtures/acpx-windows-spawn.json"
