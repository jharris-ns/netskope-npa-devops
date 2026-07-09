#!/usr/bin/env python3
"""
policy/check_guardrails.py — CI guardrail checks for personas/3-dev-team.

Checks performed (all within personas/3-dev-team/):
  1. No app has clientless_access = true           [plan JSON]
  2. All required tags present on every app        [plan JSON]
  3. Every app's tier tag is in approved_tiers     [plan JSON]
  4. All port values are quoted strings            [source files]
  5. No literal numeric publisher_id in .tf source [source files]

Checks 1-3 require a plan JSON file (--plan-file).
Checks 4-5 run on source files and always execute.

Usage:
  # Source checks only — used in CI before terraform plan:
  python3 policy/check_guardrails.py personas/3-dev-team

  # Full check — source + plan (used locally with a generated plan):
  cd personas/3-dev-team
  terraform plan -out=plan.tfplan
  terraform show -json plan.tfplan > plan.json
  python3 ../../policy/check_guardrails.py . --plan-file plan.json

  # Prove the guardrail catches bad config:
  terraform plan -var-file=terraform.tfvars.badexample -out=bad.tfplan
  terraform show -json bad.tfplan > bad.json
  python3 ../../policy/check_guardrails.py . --plan-file bad.json

Exit: 0 if all applicable checks pass, 1 if any check fails or errors.

Requirements: pip install pyyaml
"""

import argparse
import json
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML required. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(1)


# ── Colour helpers ────────────────────────────────────────────────────────────

_USE_COLOUR = True


def _c(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if _USE_COLOUR else text


def _pass(text: str) -> str:
    return _c("32;1", text)


def _fail(text: str) -> str:
    return _c("31;1", text)


def _skip(text: str) -> str:
    return _c("33", text)


def _bold(text: str) -> str:
    return _c("1", text)


# ── Taxonomy ──────────────────────────────────────────────────────────────────

def find_repo_root(start: Path) -> Path:
    """Walk up from start until we find the directory containing shared/tag-taxonomy.yaml."""
    candidate = start.resolve()
    while candidate != candidate.parent:
        if (candidate / "shared" / "tag-taxonomy.yaml").exists():
            return candidate
        candidate = candidate.parent
    raise FileNotFoundError(
        f"Could not locate shared/tag-taxonomy.yaml above {start}. "
        "Run from the repo root or any subdirectory."
    )


def load_taxonomy(repo_root: Path) -> dict:
    path = repo_root / "shared" / "tag-taxonomy.yaml"
    with open(path) as fh:
        return yaml.safe_load(fh)


# ── Plan helpers ──────────────────────────────────────────────────────────────

def get_private_apps(plan: dict) -> list:
    """Return all netskope_npa_private_app resources from planned_values."""
    resources = (
        plan
        .get("planned_values", {})
        .get("root_module", {})
        .get("resources", [])
    )
    return [r for r in resources if r.get("type") == "netskope_npa_private_app"]


def app_label(app: dict) -> str:
    idx = app.get("index")
    name = app.get("name", "unknown")
    return f"{name}[{repr(idx)}]" if idx is not None else name


# ── Check 1 — clientless_access ───────────────────────────────────────────────

def check_1_clientless_access(apps: list) -> tuple:
    """No app may have clientless_access = true."""
    failures = []
    for app in apps:
        val = app.get("values", {}).get("clientless_access")
        if val is True:
            failures.append(
                f"    {app_label(app)}: clientless_access = true  "
                "(this persona must not create browser-based apps)"
            )
    return not failures, failures


# ── Check 2 — required tags ───────────────────────────────────────────────────

def check_2_required_tags(apps: list, required_tags: list) -> tuple:
    """
    Every app must have:
      - the literal tag 'managed-by-terraform'
      - no empty tag_name values (catches tier = "" in tfvars)
      - at least as many tags as required semantic roles
    """
    failures = []
    for app in apps:
        tags = app.get("values", {}).get("tags") or []
        tag_names = [t.get("tag_name", "") for t in tags]
        label = app_label(app)

        if "managed-by-terraform" not in tag_names:
            failures.append(f"    {label}: missing 'managed-by-terraform' tag")

        empty = [i for i, n in enumerate(tag_names) if not n.strip()]
        if empty:
            failures.append(
                f"    {label}: {len(empty)} empty tag value(s) at position(s) {empty} "
                "— check that 'tier' is a non-empty string"
            )

        if len(tag_names) < len(required_tags):
            failures.append(
                f"    {label}: {len(tag_names)} tag(s) found, "
                f"expected at least {len(required_tags)} "
                f"(required roles: {', '.join(required_tags)})"
            )

    return not failures, failures


# ── Check 3 — approved tier ───────────────────────────────────────────────────

def check_3_approved_tier(apps: list, approved_tiers: list) -> tuple:
    """Every app must have exactly one tag whose value is in approved_tiers."""
    failures = []
    for app in apps:
        tags = app.get("values", {}).get("tags") or []
        tag_names = [t.get("tag_name", "") for t in tags]
        label = app_label(app)

        matching = [n for n in tag_names if n in approved_tiers]
        if not matching:
            failures.append(
                f"    {label}: no approved tier tag found.\n"
                f"      Tags present:  {tag_names}\n"
                f"      Approved tiers: {approved_tiers}"
            )
        elif len(matching) > 1:
            failures.append(
                f"    {label}: multiple tier tags found: {matching} "
                "(expected exactly one)"
            )

    return not failures, failures


# ── Check 4 — port is a string ────────────────────────────────────────────────

# Matches:  port = 9090  (unquoted integer — bad)
# Does not match: port = "22"  (quoted — good)
_PORT_UNQUOTED = re.compile(r"^\s*port\s*=\s*(\d+)\s*(?:#.*)?$")


def check_4_port_is_string(persona_dir: Path) -> tuple:
    """
    Grep .tf and .tfvars files for unquoted numeric port values.

    Terraform coerces 9090 → "9090" at the variable boundary, so the plan JSON
    always shows a string. This check must inspect raw source files.

    Note: *.badexample files are intentionally excluded — they are documentation
    showing broken config and are expected to contain unquoted ports.
    """
    failures = []
    source_files = (
        sorted(persona_dir.rglob("*.tf"))
        + sorted(persona_dir.rglob("*.tfvars"))
    )

    for fpath in source_files:
        try:
            lines = fpath.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for lineno, line in enumerate(lines, start=1):
            if line.strip().startswith("#"):
                continue
            m = _PORT_UNQUOTED.match(line)
            if m:
                rel = fpath.relative_to(persona_dir)
                failures.append(
                    f"    {rel}:{lineno}:  port = {m.group(1)}  "
                    f'(should be "{m.group(1)}")'
                )

    return not failures, failures


# ── Check 5 — no literal publisher_id ────────────────────────────────────────

# Matches:  publisher_id = 99999  (literal integer — bad)
# Skips lines that contain tostring() — that is the correct pattern
_PUBLISHER_ID_LITERAL = re.compile(r"publisher_id\s*=\s*(\d+)")


def check_5_no_literal_publisher_id(persona_dir: Path) -> tuple:
    """
    Grep .tf source for literal numeric publisher_id values.
    publisher_id must always reference a data source or resource attribute
    wrapped in tostring() — never a hardcoded integer.
    """
    failures = []

    for fpath in sorted(persona_dir.rglob("*.tf")):
        try:
            lines = fpath.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for lineno, line in enumerate(lines, start=1):
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            if "tostring" in line:
                continue  # tostring(p.publisher_id) is the correct pattern
            m = _PUBLISHER_ID_LITERAL.search(line)
            if m:
                rel = fpath.relative_to(persona_dir)
                failures.append(
                    f"    {rel}:{lineno}:  publisher_id = {m.group(1)}  "
                    "(use tostring() from a data source, e.g. tostring(p.publisher_id))"
                )

    return not failures, failures


# ── Result printer ────────────────────────────────────────────────────────────

def print_result(num: int, name: str, passed: bool, skipped: bool = False, details: list = None) -> bool:
    if skipped:
        label = _skip("SKIP")
    elif passed:
        label = _pass("PASS")
    else:
        label = _fail("FAIL")

    print(f"  [{label}] Check {num}: {name}")
    if details:
        for line in details:
            print(line)
    return passed or skipped


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    global _USE_COLOUR

    parser = argparse.ArgumentParser(
        description="CI guardrail checks for personas/3-dev-team.",
        epilog="See policy/check_guardrails.py module docstring for full usage.",
    )
    parser.add_argument(
        "persona_dir",
        help="Path to the persona directory to check (e.g. personas/3-dev-team or .)",
    )
    parser.add_argument(
        "--plan-file",
        metavar="PLAN_JSON",
        help=(
            "Path to a 'terraform show -json' output file. "
            "Required to run checks 1-3. "
            "Generate with: terraform plan -out=p.tfplan && terraform show -json p.tfplan > p.json"
        ),
    )
    parser.add_argument(
        "--no-colour",
        action="store_true",
        help="Disable ANSI colour codes (auto-disabled when stdout is not a TTY).",
    )
    args = parser.parse_args()

    if args.no_colour or not sys.stdout.isatty():
        _USE_COLOUR = False

    persona_dir = Path(args.persona_dir)
    if not persona_dir.is_dir():
        print(f"ERROR: Directory not found: {persona_dir}", file=sys.stderr)
        return 1

    # ── Load taxonomy ─────────────────────────────────────────────────────────
    try:
        repo_root = find_repo_root(persona_dir)
        taxonomy = load_taxonomy(repo_root)
        approved_tiers = taxonomy["approved_tiers"]
        required_tags = taxonomy["required_tags"]
    except (FileNotFoundError, KeyError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    # ── Header ────────────────────────────────────────────────────────────────
    print()
    print(_bold("=" * 62))
    print(_bold("  Netskope NPA CI Guardrail Checks"))
    print(_bold("=" * 62))
    print(f"  Persona dir:    {persona_dir.resolve()}")
    print(f"  Taxonomy:       {repo_root / 'shared' / 'tag-taxonomy.yaml'}")
    print(f"  Approved tiers: {approved_tiers}")
    print(f"  Required tags:  {required_tags}")
    print(f"  Plan file:      {args.plan_file or '(none — checks 1-3 will be skipped)'}")
    print()

    results = []

    # ── Plan-based checks ─────────────────────────────────────────────────────
    if args.plan_file:
        try:
            with open(args.plan_file, encoding="utf-8") as fh:
                plan = json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            print(f"ERROR: Could not read plan file: {exc}", file=sys.stderr)
            return 1

        apps = get_private_apps(plan)
        print(f"  Found {len(apps)} netskope_npa_private_app resource(s) in plan.\n")
        if not apps:
            print(
                "  WARNING: No private app resources in plan. "
                "Ensure the plan was generated from this persona directory.\n"
            )

        passed, details = check_1_clientless_access(apps)
        results.append(print_result(1, "No app has clientless_access = true", passed, details=details))

        passed, details = check_2_required_tags(apps, required_tags)
        results.append(print_result(2, "All required tags present on every app", passed, details=details))

        passed, details = check_3_approved_tier(apps, approved_tiers)
        results.append(print_result(3, "All tier tags are in approved_tiers", passed, details=details))
    else:
        results.append(print_result(1, "No app has clientless_access = true", True, skipped=True,
                                    details=["    (skipped — provide --plan-file to enable)"]))
        results.append(print_result(2, "All required tags present on every app", True, skipped=True,
                                    details=["    (skipped — provide --plan-file to enable)"]))
        results.append(print_result(3, "All tier tags are in approved_tiers", True, skipped=True,
                                    details=["    (skipped — provide --plan-file to enable)"]))

    # ── Source-based checks (always run) ─────────────────────────────────────
    passed, details = check_4_port_is_string(persona_dir)
    results.append(print_result(4, "Port values are quoted strings (not bare integers)", passed, details=details))

    passed, details = check_5_no_literal_publisher_id(persona_dir)
    results.append(print_result(5, "No literal numeric publisher_id in .tf source", passed, details=details))

    # ── Summary ───────────────────────────────────────────────────────────────
    print()
    print(_bold("-" * 62))
    failed = [i + 1 for i, r in enumerate(results) if not r]
    skipped = 0 if args.plan_file else 3

    if not failed:
        print(f"  {_pass('ALL CHECKS PASSED')} ({len(results)} checks, {skipped} skipped)")
        return 0
    else:
        print(f"  {_fail('CHECKS FAILED')} — failed: {failed}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
