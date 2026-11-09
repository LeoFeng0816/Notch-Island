#!/usr/bin/env python3
"""Pre-publish privacy/secret scan for Notch Island.

Usage:  python3 -I scripts/secret_scan.py [extra paths, e.g. a mounted DMG or .app]

Scans the project (minus build/, dist/, .git/) and any extra paths for likely
secrets, personal data and personal files. It NEVER prints a matched value:
only rule, file, line and the value's length. Exit status 1 if anything needs
review. This is a heuristic aid, not a guarantee — review the listed areas
manually before publishing.
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP_DIRS = {".git", "build", "dist", "__pycache__"}
TEXT_EXT = {".swift", ".md", ".sh", ".py", ".plist", ".entitlements", ".strings", ".json", ".txt", ".yml", ".yaml", ".gitignore", ""}
PERSONAL_MEDIA = {".png", ".jpg", ".jpeg", ".heic", ".tif", ".tiff", ".mov", ".mp4", ".gif", ".pdf"}

RULES = [
    ("aws-access-key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("github-token", re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}")),
    ("openai/anthropic-style key", re.compile(r"sk-(?:ant-)?[A-Za-z0-9_\-]{20,}")),
    ("slack-token", re.compile(r"xox[baprs]-[A-Za-z0-9\-]{10,}")),
    ("google-api-key", re.compile(r"AIza[0-9A-Za-z\-_]{35}")),
    ("discord-webhook", re.compile(r"discord(?:app)?\.com/api/webhooks/\d+/[A-Za-z0-9_\-]+")),
    ("private-key-block", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("assigned secret", re.compile(r"(?i)\b(api[_-]?key|apikey|secret|token|password|passwd)\b\s*[:=]\s*[\"']([^\"'\s]{8,})[\"']")),
    ("email address", re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")),
    ("absolute home path", re.compile(r"/Users/[A-Za-z0-9._\-]+")),
]

# Known-public values: Alpha Vantage's documented "demo" key, Apple/system addresses.
ALLOW = [
    re.compile(r"apikey[\"']?\s*[:=,]\s*[\"']demo[\"']", re.I),
    re.compile(r"apiKey: \"demo\""),
    re.compile(r"noreply@anthropic\.com"),
    re.compile(r"https://user@music\.youtube\.com/"),  # test fixture: credentials-in-URL must be rejected
]
ALLOW_EMAIL_DOMAINS = {"example.com", "anthropic.com"}


def redacted(value):
    return f"<{len(value)} chars redacted>"


def scan_text(path, rel, findings):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for number, line in enumerate(f, 1):
                if any(a.search(line) for a in ALLOW):
                    continue
                for name, rule in RULES:
                    for match in rule.finditer(line):
                        value = match.group(match.lastindex or 0)
                        if name == "email address" and value.split("@")[-1].lower() in ALLOW_EMAIL_DOMAINS:
                            continue
                        if name == "absolute home path" and value in ("/Users/Shared",):
                            continue
                        findings.append((name, rel, number, redacted(value)))
    except OSError:
        pass


def scan_binary(path, rel, findings):
    try:
        data = open(path, "rb").read()
    except OSError:
        return
    for name, rule in RULES:
        if name in ("email address",):
            continue
        pattern = re.compile(rule.pattern.encode())
        for match in pattern.finditer(data):
            findings.append((name + " (binary)", rel, 0, redacted(match.group(0))))


def is_binary(path):
    try:
        with open(path, "rb") as f:
            return b"\0" in f.read(4096)
    except OSError:
        return False


def walk(base, label, findings, media):
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for filename in filenames:
            path = os.path.join(dirpath, filename)
            rel = os.path.join(label, os.path.relpath(path, base))
            ext = os.path.splitext(filename)[1].lower()
            if ext in PERSONAL_MEDIA:
                media.append(rel)
            elif filename == ".DS_Store":
                media.append(rel)
            elif (ext in TEXT_EXT or filename in ("CLAUDE.md", "README.md")) and not is_binary(path):
                scan_text(path, rel, findings)
            elif os.access(path, os.X_OK) or ext in (".dylib", ".so", ""):
                scan_binary(path, rel, findings)


def main():
    findings, media = [], []
    walk(ROOT, ".", findings, media)
    for extra in sys.argv[1:]:
        walk(extra, os.path.basename(extra.rstrip("/")) or extra, findings, media)
    print("Notch Island secret/privacy scan (values are never printed)")
    if findings:
        print(f"\n{len(findings)} item(s) to review:")
        for name, rel, line, hint in findings:
            print(f"  [{name}] {rel}:{line} {hint}")
    if media:
        print(f"\n{len(media)} personal media / Finder file(s) (keep out of the repo or check content):")
        for rel in media:
            print(f"  {rel}")
    if not findings and not media:
        print("No findings.")
    return 1 if findings or media else 0


if __name__ == "__main__":
    sys.exit(main())
