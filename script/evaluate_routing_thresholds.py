#!/usr/bin/env python3
"""Offline sensitivity check for the OLD combined-choice holdout (no HTTP).

This is not a quality evaluation of the new independent model/effort questions.
Only aggregate results and input hashes are printed; prompts stay in local files.
Usage: python3 script/evaluate_routing_thresholds.py /tmp/switchgpt-router-goal
"""
import hashlib
import json
import math
import sys
from pathlib import Path


def evaluate(directory):
    scored_path = directory / "scored.json"
    cases_path = directory / "cases.json"
    scored = json.loads(scored_path.read_text())
    cases = {int(row["id"]): row for row in json.loads(cases_path.read_text())}
    models = {"gpt-5.6-luna": 0, "gpt-5.6-sol": 1, "gpt-6-astra": 2}
    families = {"luna": 0, "sol": 1, "astra": 2}
    efforts = {"medium": 1, "high": 2, "max": 4}
    results = []
    ids = [int(row["id"].removeprefix("H")) for row in scored]
    if len(set(ids)) != len(ids) or set(ids) != set(cases):
        raise ValueError("Scored and input case IDs must match uniquely")
    for upgrade, downgrade in [(0.8, 0.8), (0.65, 0.85), (0.8, 0.85), (0.8, 0.9)]:
        counts = dict(accepted=0, agreement=0, keep_violations=0, changed=0)
        for row, case_id in zip(scored, ids):
            original = cases[case_id]
            choice = row["choice"]
            confidence = row["confidence"]
            if not math.isfinite(confidence) or not 0 <= confidence <= 1:
                raise ValueError("Invalid historical confidence")
            if choice == "keep":
                continue
            family, effort = choice.split("_")
            current_model = models[original["model"]]
            current_effort = efforts[original["effort"]]
            goes_down = families[family] < current_model or efforts[effort] < current_effort
            if confidence < (downgrade if goes_down else upgrade):
                continue
            counts["accepted"] += 1
            counts["agreement"] += choice in row["allowed"]
            counts["keep_violations"] += row["allowed"] == ["keep"]
            counts["changed"] += families[family] != current_model or efforts[effort] != current_effort
        results.append(dict(upgrade=upgrade, downgrade=downgrade, **counts))
    return {
        "scope": "historical combined-choice sensitivity only; not new-schema validation",
        "cases": len(scored),
        "sha256": {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                   for path in (scored_path, cases_path)},
        "results": results,
    }


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: evaluate_routing_thresholds.py <historical-holdout-directory>")
    print(json.dumps(evaluate(Path(sys.argv[1])), indent=2))
