// A Windows file system for acpx's resolution: names compare without case, as NTFS does, and
// Win32 reads either slash, resolves `.` and `..`, and takes a relative path from the process's
// directory (`process.cwd()`, which cases.ts sets), as it does.
import nodePath from "node:path";

const existing = new Set<string>();
const directories = new Set<string>();
const texts = new Map<string, string>();
const canonical = (file: string) => nodePath.win32.resolve(file).toLowerCase();

export const fakeFs = {
  set(files: string[], folders: string[] = [], contents: Record<string, string> = {}) {
    existing.clear();
    directories.clear();
    texts.clear();
    for (const file of files) existing.add(canonical(file));
    for (const folder of folders) directories.add(canonical(folder));
    for (const [file, text] of Object.entries(contents)) texts.set(canonical(file), text);
  },
  existsSync(file: string): boolean {
    return existing.has(canonical(file)) || directories.has(canonical(file));
  },
  readFileSync(file: string): string {
    const text = texts.get(canonical(file));
    if (text === undefined) throw new Error("not in the fake file system");
    return text;
  },
  statSync(file: string): { isFile: () => boolean } | undefined {
    if (existing.has(canonical(file))) return { isFile: () => true };
    return directories.has(canonical(file)) ? { isFile: () => false } : undefined;
  },
  accessSync(): void {
    throw new Error("not in the fake file system");
  },
  constants: { X_OK: 1 },
};
