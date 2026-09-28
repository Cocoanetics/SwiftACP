// A Windows file system for acpx's resolution: names compare without case, as NTFS does, and
// Win32 reads either slash and resolves `.` and `..`, as it does.
import nodePath from "node:path";

const existing = new Set<string>();
const canonical = (file: string) => nodePath.win32.normalize(file).toLowerCase();

export const fakeFs = {
  set(files: string[]) {
    existing.clear();
    for (const file of files) existing.add(canonical(file));
  },
  existsSync(file: string): boolean {
    return existing.has(canonical(file));
  },
  readFileSync(): string {
    throw new Error("not in the fake file system");
  },
  statSync(): undefined {
    return undefined;
  },
  accessSync(): void {
    throw new Error("not in the fake file system");
  },
  constants: { X_OK: 1 },
};
