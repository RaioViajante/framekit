"""JSON Schema checks: the schemas are valid draft 2020-12, accept the shipped presets and examples, and
give the verdict that captions/schemas/conformance.json states for every shared case. The Swift tests hold
the validator to the same cases (Tests/FrameKitCaptionsTests/SchemaParityTests.swift).

Needs check-jsonschema at the version pinned in captions/schemas/requirements-dev.txt, found through
$FRAMEKIT_CHECK_JSONSCHEMA or on PATH; without it those tests are skipped (skipped is not passed).
Development and CI only: nothing here is a runtime dependency.

Run: python3 -I -m unittest discover -s captions/tests
"""
import glob
import json
import os
import shutil
import subprocess
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCHEMAS = {"preset": "captions/schemas/caption-preset.v1.schema.json",
           "input": "captions/schemas/caption-input.v1.schema.json"}
REQUIREMENTS = os.path.join(REPO, "captions", "schemas", "requirements-dev.txt")


def load(path):
    with open(os.path.join(REPO, path), encoding="utf-8") as f:
        return json.load(f)


def setting(doc, path, value, remove=False):
    """The same change as JSONValue.setting in the Swift tests: dotted path, numeric keys index arrays."""
    keys = path.split(".")
    node = doc
    for key in keys[:-1]:
        node = node[int(key)] if isinstance(node, list) else node[key]
    last = keys[-1]
    if isinstance(node, list):
        if remove:
            del node[int(last)]
        else:
            node[int(last)] = value
    elif remove:
        del node[last]
    else:
        node[last] = value


def case_documents():
    conformance = load("captions/schemas/conformance.json")
    out = []
    for case in conformance["cases"]:
        doc = load(conformance["bases"][case["document"]])
        for path in sorted(case.get("set", {})):
            setting(doc, path, json.loads(json.dumps(case["set"][path])))
        for path in case.get("remove", []):
            setting(doc, path, None, remove=True)
        out.append((case, doc))
    return out


def pinned_version():
    with open(REQUIREMENTS, encoding="utf-8") as f:
        lines = [l.strip() for l in f if l.strip() and not l.startswith("#")]
    return dict(l.split("==") for l in lines)["check-jsonschema"]


def checker():
    path = os.environ.get("FRAMEKIT_CHECK_JSONSCHEMA") or shutil.which("check-jsonschema")
    if not path:
        return None
    r = subprocess.run([path, "--version"], capture_output=True, text=True)
    return path, r.stdout.strip().rsplit(" ", 1)[-1]


class ConformanceCases(unittest.TestCase):
    """Portable: the shared cases are well formed."""

    def test_cases_are_well_formed(self):
        conformance = load("captions/schemas/conformance.json")
        names = [c["name"] for c in conformance["cases"]]
        self.assertEqual(len(names), len(set(names)))
        for case in conformance["cases"]:
            self.assertIn(case["document"], conformance["bases"])
            self.assertIsInstance(case["schema"], bool)
            self.assertLessEqual(set(case), {"name", "document", "set", "remove", "schema", "validator", "against_preset"})
            if case.get("against_preset"):
                self.assertEqual(case["document"], "input")
        for document in ("preset", "input"):
            self.assertTrue(any(c["schema"] for c in conformance["cases"] if c["document"] == document))
            self.assertTrue(any(not c["schema"] for c in conformance["cases"] if c["document"] == document))

    def test_every_case_applies_to_its_base(self):
        self.assertGreaterEqual(len(case_documents()), 50)

    def test_the_checker_version_is_pinned(self):
        self.assertRegex(pinned_version(), r"^\d+\.\d+\.\d+$")


class SchemaVerdicts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        found = checker()
        if not found:
            raise unittest.SkipTest("check-jsonschema not found; see captions/schemas/requirements-dev.txt")
        cls.path, version = found
        if version != pinned_version():
            raise AssertionError("check-jsonschema %s, but %s is pinned" % (version, pinned_version()))

    def run_checker(self, *args):
        return subprocess.run([self.path, *args], capture_output=True, text=True, cwd=REPO)

    def test_schemas_are_valid_draft_2020_12(self):
        r = self.run_checker("--check-metaschema", *SCHEMAS.values())
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_shipped_presets_and_examples_are_accepted(self):
        for document, files in (("preset", sorted(glob.glob(os.path.join(REPO, "captions/presets/*.json")))),
                                ("input", sorted(glob.glob(os.path.join(REPO, "captions/examples/*.json"))))):
            self.assertTrue(files)
            r = self.run_checker("--schemafile", SCHEMAS[document], *files)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_every_shared_case_gets_the_stated_verdict(self):
        with tempfile.TemporaryDirectory() as tmp:
            files = {"preset": [], "input": []}
            expected = {}
            for i, (case, doc) in enumerate(case_documents()):
                path = os.path.join(tmp, "case-%03d.json" % i)
                with open(path, "w", encoding="utf-8") as f:
                    json.dump(doc, f, ensure_ascii=False)
                files[case["document"]].append(path)
                expected[os.path.basename(path)] = case
            rejected = set()
            for document, paths in files.items():
                r = self.run_checker("--output-format", "json", "--schemafile", SCHEMAS[document], *paths)
                report = json.loads(r.stdout)
                self.assertEqual(report["parse_errors"], [])
                rejected |= {os.path.basename(e["filename"]) for e in report["errors"]}
            wrong = ["%s: schema %s" % (case["name"], "rejects" if name in rejected else "accepts")
                     for name, case in sorted(expected.items()) if (name not in rejected) != case["schema"]]
            self.assertEqual(wrong, [])


if __name__ == "__main__":
    unittest.main()
