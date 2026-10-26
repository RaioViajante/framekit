"""Documentation checks (portable): relative links and anchors resolve, README commands point at files
that exist, and the README sticker is referenced safely and still matches the hash its notice records.

Run: python3 -I -m unittest discover -s captions/tests
"""
import hashlib
import os
import re
import shutil
import struct
import subprocess
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def markdown_files():
    out = []
    for root, dirs, files in os.walk(REPO):
        dirs[:] = [d for d in dirs if d not in (".git", "build", ".build", ".swiftpm", "__pycache__")]
        out += [os.path.join(root, f) for f in files if f.endswith(".md")]
    return sorted(out)


def slug(heading):
    """GitHub's anchor for a heading: lowercase, drop punctuation, spaces become hyphens."""
    text = re.sub(r"[`*_]", "", heading.strip().lower())
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def anchors(path):
    found = set()
    in_code = False
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.lstrip().startswith("```"):
                in_code = not in_code
            elif not in_code:
                m = re.match(r"#{1,6}\s+(.*)", line)
                if m:
                    found.add(slug(m.group(1)))
    return found


def targets(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    text = re.sub(r"```.*?```", "", text, flags=re.S)  # links inside code blocks are examples
    found = re.findall(r"\]\(([^)\s]+)\)", text)
    found += re.findall(r'(?:href|src)="([^"]+)"', text)
    return found


def tracked_paths():
    """Case-exact set of repository paths according to Git (tracked plus untracked, not ignored), or None.

    macOS file systems are case-insensitive, so a link such as docs/development.md can resolve on disk
    while Git (and therefore GitHub) knows the file as docs/DEVELOPMENT.md. Comparing with Git's own
    names catches that.
    """
    if not shutil.which("git") or not os.path.isdir(os.path.join(REPO, ".git")):
        return None
    r = subprocess.run(["git", "-C", REPO, "ls-files", "--cached", "--others", "--exclude-standard"],
                       capture_output=True, text=True)
    return set(r.stdout.splitlines()) if r.returncode == 0 else None


class DocumentationLinks(unittest.TestCase):
    def test_every_relative_link_and_anchor_resolves(self):
        problems = []
        for md in markdown_files():
            for target in targets(md):
                if re.match(r"^(https?:|mailto:)", target):
                    continue
                ref, _, fragment = target.partition("#")
                dest = md if not ref else os.path.normpath(os.path.join(os.path.dirname(md), ref))
                rel = os.path.relpath(md, REPO)
                if not os.path.exists(dest):
                    problems.append("%s: %s does not exist" % (rel, target))
                elif fragment and dest.endswith(".md") and fragment not in anchors(dest):
                    problems.append("%s: anchor #%s not found in %s" % (rel, fragment, os.path.relpath(dest, REPO)))
        self.assertEqual(problems, [])

    def test_links_use_the_exact_case_that_git_records(self):
        tracked = tracked_paths()
        if tracked is None:
            self.skipTest("not a Git checkout")
        problems = []
        for md in markdown_files():
            for target in targets(md):
                if re.match(r"^(https?:|mailto:)", target):
                    continue
                ref = target.partition("#")[0]
                if not ref:
                    continue
                rel = os.path.relpath(os.path.normpath(os.path.join(os.path.dirname(md), ref)), REPO)
                is_dir = os.path.isdir(os.path.join(REPO, rel))
                found = any(t.startswith(rel.rstrip("/") + "/") for t in tracked) if is_dir else rel in tracked
                if not found:
                    problems.append("%s: %s is not a path Git records (check the letter case)" % (os.path.relpath(md, REPO), target))
        self.assertEqual(problems, [])

    def test_no_two_tracked_paths_differ_only_by_case(self):
        tracked = tracked_paths()
        if tracked is None:
            self.skipTest("not a Git checkout")
        lowered = {}
        for t in tracked:
            lowered.setdefault(t.lower(), []).append(t)
        self.assertEqual([v for v in lowered.values() if len(v) > 1], [])

    def test_readme_commands_reference_existing_paths(self):
        readme = os.path.join(REPO, "README.md")
        with open(readme, encoding="utf-8") as f:
            text = f.read()
        blocks = re.findall(r"```sh\n(.*?)```", text, flags=re.S)
        self.assertTrue(blocks, "README has no sh block")
        paths = set()
        for block in blocks:
            paths.update(re.findall(r"\b(captions/[\w./-]+)", block))
        self.assertTrue(paths)
        for p in paths:
            self.assertTrue(os.path.exists(os.path.join(REPO, p)), p)

    def test_documented_commands_in_docs_reference_existing_paths(self):
        for md in markdown_files():
            with open(md, encoding="utf-8") as f:
                text = f.read()
            for block in re.findall(r"```sh\n(.*?)```", text, flags=re.S):
                for p in re.findall(r"\b((?:captions|docs|assets)/[\w./-]+)", block):
                    self.assertTrue(os.path.exists(os.path.join(REPO, p)) or p.startswith("captions/tests/fixtures"),
                                    "%s: %s" % (os.path.relpath(md, REPO), p))


class Sticker(unittest.TestCase):
    path = os.path.join(REPO, "assets", "brand", "framekit-sticker.png")

    def test_readme_references_the_sticker_safely(self):
        with open(os.path.join(REPO, "README.md"), encoding="utf-8") as f:
            text = f.read()
        imgs = re.findall(r"<img\b[^>]*>", text)
        self.assertEqual(len(imgs), 1)
        img = imgs[0]
        self.assertIn('src="assets/brand/framekit-sticker.png"', img)
        self.assertRegex(img, r'alt="[^"]{20,}"')
        self.assertNotIn("data:", text)
        self.assertNotRegex(img, r'src="https?:')

    def test_sticker_is_an_unmodified_rgba_png_matching_its_notice(self):
        with open(self.path, "rb") as f:
            data = f.read()
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        width, height, depth, ctype = struct.unpack(">IIBB", data[16:26])
        self.assertEqual((width, height, depth, ctype), (1254, 1254, 8, 6))  # RGBA keeps its transparency
        self.assertLess(len(data), 5 * 1024 * 1024)
        with open(os.path.join(REPO, "assets", "brand", "NOTICE.md"), encoding="utf-8") as f:
            notice = f.read()
        self.assertIn(hashlib.sha256(data).hexdigest(), notice)


if __name__ == "__main__":
    unittest.main()
