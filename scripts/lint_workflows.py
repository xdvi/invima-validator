#!/usr/bin/env python3
"""Rejects `${{ }}` expressions inside workflow `run:` bodies. `--self-test` checks the detector."""

import pathlib
import re
import sys
import tempfile

try:
    import yaml
except ModuleNotFoundError:
    sys.exit("PyYAML is required: apt-get install python3-yaml (or pip install pyyaml)")

EXPRESSION = re.compile(r"\$\{\{.*?\}\}", re.DOTALL)
WORKFLOW_DIR = pathlib.Path(__file__).resolve().parent.parent / ".github" / "workflows"
INJECTED_YAML = "jobs:\n  j:\n    steps:\n      - run: echo ${{ github.ref_name }}\n"


def steps_of(job):
    if isinstance(job, dict) and isinstance(job.get("steps"), list):
        return [s for s in job["steps"] if isinstance(s, dict)]
    return []


def scan(name, document):
    jobs = document.get("jobs") if isinstance(document, dict) else None
    if not isinstance(jobs, dict):
        raise ValueError(f"{name}: no 'jobs' mapping; refusing to treat it as clean")

    found = []
    for job_name, job in jobs.items():
        for index, step in enumerate(steps_of(job)):
            script = step.get("run")
            if not isinstance(script, str):
                continue
            for expression in EXPRESSION.findall(script):
                label = step.get("name") or f"step #{index + 1}"
                found.append(f"{name}: job '{job_name}', {label}: {expression.strip()}")
    return found


def inspect(path):
    try:
        return scan(path.name, yaml.safe_load(path.read_text(encoding="utf-8"))), []
    except (yaml.YAMLError, OSError, UnicodeDecodeError, ValueError) as exc:
        return [], [str(exc) if isinstance(exc, ValueError) else f"{path.name}: unreadable: {exc}"]


def self_test():
    injected = {"jobs": {"j": {"steps": [{"run": "gh release create ${{ github.ref_name }} x"}]}}}
    # The expression itself straddles the newline, so this fails without re.DOTALL.
    spanning = {"jobs": {"j": {"steps": [{"run": "echo '${{ github.event.issue.title\n  }}'"}]}}}
    safe = {"jobs": {"j": {"steps": [{"env": {"TAG": "${{ github.ref_name }}"}, "run": 'echo "$TAG"'}]}}}
    shapes = {"jobs": {"call": {"uses": "./wf.yml"}, "odd": {"steps": ["x", {"run": 42}]}}}
    checks = [
        ("detects an injected expression", lambda: len(scan("t", injected)) == 1),
        ("detects an expression spanning lines", lambda: len(scan("t", spanning)) == 1),
        ("allows values passed through env:", lambda: scan("t", safe) == []),
        ("tolerates jobs without usable steps", lambda: scan("t", shapes) == []),
        ("rejects a document without jobs", lambda: _raises(lambda: scan("t", {}))),
        ("rejects an empty document", lambda: _raises(lambda: scan("t", None))),
        ("reports an injection read from a file", lambda: _inspect_finds(INJECTED_YAML, 1, 0)),
        ("fails closed on unparseable yaml", lambda: _inspect_finds("a:\n  b: [\n", 0, 1)),
        ("fails closed on an empty file", lambda: _inspect_finds("", 0, 1)),
    ]
    failed = [label for label, check in checks if not check()]
    for label in failed:
        print(f"self-test FAILED: {label}", file=sys.stderr)
    if failed:
        return 1
    print(f"self-test: {len(checks)} checks passed.")
    return 0


def _raises(call):
    try:
        call()
    except ValueError:
        return True
    return False


def _inspect_finds(text, violations, errors):
    """Runs the real file-reading path so a break there cannot pass unnoticed."""
    with tempfile.TemporaryDirectory() as directory:
        path = pathlib.Path(directory) / "probe.yml"
        path.write_text(text, encoding="utf-8")
        found, failed = inspect(path)
    return len(found) == violations and len(failed) == errors


def main():
    if "--self-test" in sys.argv:
        return self_test()

    workflows = sorted(WORKFLOW_DIR.glob("*.yml")) + sorted(WORKFLOW_DIR.glob("*.yaml"))
    if not workflows:
        print(f"No workflows found under {WORKFLOW_DIR}", file=sys.stderr)
        return 1

    violations, errors = [], []
    for path in workflows:
        found, failed = inspect(path)
        violations += found
        errors += failed

    for header, items in (
        ("Could not verify every workflow:", errors),
        ("Expression substituted into a run: body (pass it through env: instead):", violations),
    ):
        if items:
            print(header, file=sys.stderr)
            for item in items:
                print(f"  {item}", file=sys.stderr)
    if errors or violations:
        return 1

    print(f"{len(workflows)} workflow(s) clean: no expressions inside run: bodies.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
