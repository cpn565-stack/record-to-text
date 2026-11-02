#!/usr/bin/env python3
"""Preview disposable development artifacts; --apply moves them to Trash."""
import argparse
import datetime
import json
import plistlib
import re
import shutil
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="move listed items to Trash")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    version = (root / "Config/version.env").read_text()
    current = int(re.search(r"^DEFAULT_BUILD_NUMBER=(\d+)$", version, re.M)[1])
    marketing = re.search(r"^MARKETING_VERSION=([\d.]+)$", version, re.M)[1]
    candidates = [root / ".build", root / "runtime/macos-arm64/downloads"]
    # Keep the current and any newer builds. Do not sweep arbitrary files in
    # dist: it also contains historical transcripts and recovery evidence.
    for dmg in sorted((root / "dist").glob("record-to-text-*-build*-development.dmg")):
        match = re.fullmatch(r"record-to-text-" + re.escape(marketing) + r"-build(\d+)-development\.dmg", dmg.name)
        if match and int(match[1]) < current:
            candidates.extend([dmg, dmg.with_name(dmg.name + ".sha256")])
    for app in sorted((root / "dist/install-backups").glob("*/record-to-text.app")):
        try:
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            if (info.get("CFBundleIdentifier") == "com.specifique.record-to-text"
                    and info.get("CFBundleShortVersionString") == marketing
                    and int(info["CFBundleVersion"]) < current):
                candidates.append(app)
        except (OSError, ValueError, KeyError, plistlib.InvalidFileException):
            continue
    candidates = [p for p in candidates if p.exists() and not p.is_symlink()]
    for path in candidates:
        # Refuse redirected ancestors or anything tracked by Git.
        if path.resolve() != path or subprocess.check_output(
            ["git", "ls-files", "--", str(path.relative_to(root))], cwd=root
        ).strip():
            raise SystemExit(f"Refusing to clean protected path: {path}")
    if args.apply:
        processes = subprocess.check_output(["ps", "-axo", "command="], text=True)
        if any(str(root / ".build") in line or re.search(r"(?:^|/)(?:swift-build|swift-test)(?:\s|$)", line)
               for line in processes.splitlines()):
            raise SystemExit("A build/test process may be using .build; quit it before cleanup.")
    total = 0
    for path in candidates:
        kib = int(subprocess.check_output(["du", "-sk", str(path)], text=True).split()[0])
        total += kib
        print(f"{kib / 1024:8.1f} MiB  {path.relative_to(root)}")
    print(f"Total: {total / 1024:.1f} MiB. Source, tests, documents, model caches and job data are preserved.")
    if not args.apply or not candidates:
        if not args.apply:
            print("Preview only. Run with --apply to move these items to Trash.")
        return
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    destination = Path.home() / ".Trash" / f"record-to-text-development-{stamp}"
    destination.mkdir(parents=True, exist_ok=False)
    manifest = {"source_root": str(root), "paths": [str(p.relative_to(root)) for p in candidates]}
    (destination / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    for path in candidates:
        target = destination / path.relative_to(root)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(path), str(target))
    print(f"Moved to {destination}. Emptying Trash later releases the disk space.")


if __name__ == "__main__":
    main()
