"""Patch Vibe 0.1.15 swarm runtime to hand upstream artifacts to downstream agents.

Workers are intentionally isolated under artifacts/<agent_id>. Upstream summaries flow
through input_from, but the actual files did not. This patch stages each upstream
agent's artifact tree under the downstream workspace at upstream/<context_key>/,
including after retries, so auditors/judges can read manifests and metrics safely.
"""
from __future__ import annotations

import importlib.util
import py_compile
from pathlib import Path

spec = importlib.util.find_spec("src.swarm.runtime")
if spec is None or not spec.origin:
    raise SystemExit("VIBE_SWARM_RUNTIME_NOT_FOUND")

path = Path(spec.origin).resolve()
text = path.read_text(encoding="utf-8")
original = text
marker = "Upstream artifacts staged at upstream/"

if marker not in text:
    old = '''                # Build upstream summaries from input_from mapping
                upstream: dict[str, str] = {}
                for context_key, source_task_id in task.input_from.items():
                    if source_task_id in task_summaries:
                        upstream[context_key] = task_summaries[source_task_id]

                future = executor.submit(
                    self._run_worker_with_retries,
'''
    new = '''                # Build upstream summaries and stageable artifact sources from
                # input_from mapping. Downstream workers have isolated workspaces,
                # so artifact handoff must be explicit instead of assuming read_file
                # can cross agent directories.
                upstream: dict[str, str] = {}
                upstream_artifact_dirs: dict[str, Path] = {}
                for context_key, source_task_id in task.input_from.items():
                    if source_task_id in task_summaries:
                        upstream[context_key] = (
                            task_summaries[source_task_id]
                            + f"\\n\\n[Upstream artifacts staged at upstream/{context_key}/]"
                        )
                    try:
                        source_task = task_store.load_task(source_task_id)
                    except FileNotFoundError:
                        source_task = None
                    if source_task is not None:
                        source_dir = agent_artifact_dir(run_dir, source_task.agent_id)
                        if source_dir.exists():
                            upstream_artifact_dirs[context_key] = source_dir

                future = executor.submit(
                    self._run_worker_with_retries,
'''
    if old not in text:
        raise SystemExit("VIBE_UPSTREAM_HANDOFF_SCHEDULER_ANCHOR_NOT_FOUND")
    text = text.replace(old, new, 1)

    old = '''                    task=task,
                    upstream_summaries=upstream,
                    user_vars=run.user_vars,
'''
    new = '''                    task=task,
                    upstream_summaries=upstream,
                    upstream_artifact_dirs=upstream_artifact_dirs,
                    user_vars=run.user_vars,
'''
    if old not in text:
        raise SystemExit("VIBE_UPSTREAM_HANDOFF_SUBMIT_ANCHOR_NOT_FOUND")
    text = text.replace(old, new, 1)

    old = '''        task: SwarmTask,
        upstream_summaries: dict[str, str],
        user_vars: dict[str, str],
'''
    new = '''        task: SwarmTask,
        upstream_summaries: dict[str, str],
        upstream_artifact_dirs: dict[str, Path],
        user_vars: dict[str, str],
'''
    if old not in text:
        raise SystemExit("VIBE_UPSTREAM_HANDOFF_SIGNATURE_ANCHOR_NOT_FOUND")
    text = text.replace(old, new, 1)

    old = '''            task: The task to execute.
            upstream_summaries: Summaries from upstream tasks.
            user_vars: User-provided template variables.
'''
    new = '''            task: The task to execute.
            upstream_summaries: Summaries from upstream tasks.
            upstream_artifact_dirs: Upstream agent artifact directories keyed by input_from context key.
            user_vars: User-provided template variables.
'''
    if old not in text:
        raise SystemExit("VIBE_UPSTREAM_HANDOFF_DOC_ANCHOR_NOT_FOUND")
    text = text.replace(old, new, 1)

    old = '''            result = run_worker(
                agent_spec=agent_spec,
'''
    new = '''            # Stage upstream evidence inside this worker's isolated workspace.
            # read_file/write_file are confined to the current agent directory, so
            # without this copy downstream auditors can see only summaries, not the
            # actual manifests/metrics/trades produced by upstream workers.
            current_artifact_dir = agent_artifact_dir(run_dir, agent_spec.id)
            current_artifact_dir.mkdir(parents=True, exist_ok=True)
            upstream_root = current_artifact_dir / "upstream"
            upstream_root.mkdir(parents=True, exist_ok=True)
            for context_key, source_dir in upstream_artifact_dirs.items():
                target_dir = upstream_root / context_key
                if target_dir.exists():
                    shutil.rmtree(target_dir)
                shutil.copytree(source_dir, target_dir)

            result = run_worker(
                agent_spec=agent_spec,
'''
    if old not in text:
        raise SystemExit("VIBE_UPSTREAM_HANDOFF_STAGE_ANCHOR_NOT_FOUND")
    text = text.replace(old, new, 1)


# Downstream workers only have read_file; they cannot enumerate an arbitrary
# workspace directory. Publish an index beside every staged upstream tree so
# auditors/judges can discover dynamic candidate paths deterministically.
index_marker = "vibe.upstream_artifact_index.v1"
if index_marker not in text:
    if "import json\n" not in text:
        text = text.replace("import logging\n", "import json\nimport logging\n", 1)

    old_summary = '''                            + f"\\n\\n[Upstream artifacts staged at upstream/{context_key}/]"
'''
    new_summary = '''                            + f"\\n\\n[Upstream artifacts staged at upstream/{context_key}/. "
                              f"Read upstream/{context_key}/artifact_index.json first, then open exact files listed there.]"
'''
    if old_summary in text:
        text = text.replace(old_summary, new_summary, 1)

    old_stage = '''                if target_dir.exists():
                    shutil.rmtree(target_dir)
                shutil.copytree(source_dir, target_dir)

            result = run_worker(
'''
    new_stage = '''                if target_dir.exists():
                    shutil.rmtree(target_dir)
                shutil.copytree(source_dir, target_dir)

                # read_file has no directory-enumeration primitive. Publish a
                # deterministic file index so downstream auditors can discover
                # candidate manifests and evidence without guessing paths.
                staged_files = sorted(
                    path.relative_to(target_dir).as_posix()
                    for path in target_dir.rglob("*")
                    if path.is_file()
                )
                (target_dir / "artifact_index.json").write_text(
                    json.dumps(
                        {
                            "schema": "vibe.upstream_artifact_index.v1",
                            "context_key": context_key,
                            "file_count": len(staged_files),
                            "files": staged_files,
                        },
                        ensure_ascii=False,
                        indent=2,
                    ),
                    encoding="utf-8",
                )

            result = run_worker(
'''
    if old_stage not in text:
        raise SystemExit("VIBE_UPSTREAM_ARTIFACT_INDEX_STAGE_ANCHOR_NOT_FOUND")
    text = text.replace(old_stage, new_stage, 1)


# Publish a compact evidence bundle so downstream auditors do not need dozens of
# read_file calls or rely on partial/truncated context.
bundle_marker = "vibe.upstream_evidence_bundle.v1"
if bundle_marker not in text:
    if "import csv\n" not in text:
        text = text.replace("import json\n", "import csv\nimport json\n", 1)

    helper_anchor = "logger = logging.getLogger(__name__)\\n\\n"
    helper = r'''
def _read_json_if_exists(path: Path) -> dict:
    try:
        if path.is_file():
            data = json.loads(path.read_text(encoding="utf-8"))
            return data if isinstance(data, dict) else {}
    except Exception:
        return {}
    return {}


def _read_first_csv_row(path: Path) -> dict:
    try:
        if not path.is_file():
            return {}
        with path.open("r", encoding="utf-8-sig", newline="") as handle:
            reader = csv.DictReader(handle)
            row = next(reader, None)
            return dict(row or {})
    except Exception:
        return {}


def _compact_validation(path: Path) -> dict:
    data = _read_json_if_exists(path)
    if not data:
        return {}
    bootstrap = data.get("bootstrap") if isinstance(data.get("bootstrap"), dict) else {}
    walk = data.get("walk_forward") if isinstance(data.get("walk_forward"), dict) else {}
    return {
        "bootstrap": {
            key: bootstrap.get(key)
            for key in (
                "observed_sharpe", "ci_lower", "ci_upper", "median_sharpe",
                "prob_positive", "confidence", "n_bootstrap",
            )
            if key in bootstrap
        },
        "walk_forward": {
            key: walk.get(key)
            for key in (
                "n_windows", "windows", "profitable_windows", "consistency_rate",
                "return_mean", "return_std", "sharpe_mean", "sharpe_std",
            )
            if key in walk
        },
    }


def _write_upstream_evidence_bundle(context_key: str, target_dir: Path) -> Path:
    file_paths = sorted(
        path.relative_to(target_dir).as_posix()
        for path in target_dir.rglob("*")
        if path.is_file() and path.name != "evidence_bundle.json"
    )
    payload: dict = {
        "schema": "vibe.upstream_evidence_bundle.v1",
        "context_key": context_key,
        "file_count": len(file_paths),
        "candidate_count": 0,
        "sqx_ready_count": 0,
        "candidates": [],
    }

    runs_dir = target_dir / "runs"
    if runs_dir.is_dir():
        candidates = []
        for run_dir in sorted(path for path in runs_dir.iterdir() if path.is_dir()):
            manifest = _read_json_if_exists(run_dir / "strategy_manifest.json")
            metrics = _read_first_csv_row(run_dir / "artifacts" / "metrics.csv")
            validation = _compact_validation(run_dir / "artifacts" / "validation.json")
            config = _read_json_if_exists(run_dir / "config.json")
            status = str(
                manifest.get("status")
                or ("MANIFEST_MISSING" if not manifest else "UNKNOWN")
            )
            metric_subset = {
                key: metrics.get(key)
                for key in (
                    "total_return", "annual_return", "max_drawdown", "sharpe",
                    "sortino", "win_rate", "profit_loss_ratio", "profit_factor",
                    "trade_count", "benchmark_return", "excess_return",
                )
                if key in metrics
            }
            candidates.append({
                "candidate_id": str(manifest.get("candidate_id") or run_dir.name),
                "status": status,
                "manifest_present": bool(manifest),
                "metrics_present": bool(metrics),
                "validation_present": bool(validation),
                "target": manifest.get("target"),
                "timeframe": manifest.get("timeframe"),
                "direction": manifest.get("direction"),
                "evaluated_window": manifest.get("evaluated_window"),
                "routing": {
                    "manifest_data_source": manifest.get("data_source"),
                    "config_source": config.get("source"),
                    "config_codes": config.get("codes"),
                    "config_interval": config.get("interval"),
                    "config_start_date": config.get("start_date"),
                    "config_end_date": config.get("end_date"),
                },
                "manifest_metrics": {
                    key: manifest.get(key)
                    for key in ("trade_count", "return", "Sharpe", "max_drawdown")
                    if key in manifest
                },
                "engine_metrics": metric_subset,
                "validation": validation,
                "files": {
                    "manifest": f"runs/{run_dir.name}/strategy_manifest.json"
                    if (run_dir / "strategy_manifest.json").is_file() else None,
                    "metrics": f"runs/{run_dir.name}/artifacts/metrics.csv"
                    if (run_dir / "artifacts" / "metrics.csv").is_file() else None,
                    "validation": f"runs/{run_dir.name}/artifacts/validation.json"
                    if (run_dir / "artifacts" / "validation.json").is_file() else None,
                    "trades": f"runs/{run_dir.name}/artifacts/trades.csv"
                    if (run_dir / "artifacts" / "trades.csv").is_file() else None,
                    "equity": f"runs/{run_dir.name}/artifacts/equity.csv"
                    if (run_dir / "artifacts" / "equity.csv").is_file() else None,
                },
            })
        payload["candidates"] = candidates
        payload["candidate_count"] = len(candidates)
        payload["sqx_ready_count"] = sum(
            1 for candidate in candidates if candidate.get("status") == "SQX_READY"
        )
    else:
        for name in ("summary.md", "report.md"):
            report_path = target_dir / name
            if report_path.is_file():
                try:
                    payload[name.replace(".", "_")] = report_path.read_text(
                        encoding="utf-8"
                    )[:3000]
                except Exception:
                    pass

    bundle_path = target_dir / "evidence_bundle.json"
    bundle_path.write_text(
        json.dumps(payload, ensure_ascii=False, separators=(",", ":"), default=str),
        encoding="utf-8",
    )
    return bundle_path


'''
    if helper_anchor not in text:
        raise SystemExit("VIBE_EVIDENCE_BUNDLE_HELPER_ANCHOR_NOT_FOUND")
    text = text.replace(helper_anchor, helper_anchor + helper, 1)

    old_summary = '''                              f"Read upstream/{context_key}/artifact_index.json first, then open exact files listed there.]"
'''
    new_summary = '''                              f"Read upstream/{context_key}/evidence_bundle.json FIRST for the compact verified digest. "
                              f"Use upstream/{context_key}/artifact_index.json only when additional exact files are needed.]"
'''
    if old_summary in text:
        text = text.replace(old_summary, new_summary, 1)

    stage_anchor = '''                    encoding="utf-8",
                )

            result = run_worker(
'''
    stage_replacement = '''                    encoding="utf-8",
                )
                _write_upstream_evidence_bundle(context_key, target_dir)

            result = run_worker(
'''
    if stage_anchor not in text:
        raise SystemExit("VIBE_EVIDENCE_BUNDLE_STAGE_ANCHOR_NOT_FOUND")
    text = text.replace(stage_anchor, stage_replacement, 1)


if text != original:
    backup = path.with_suffix(path.suffix + ".before-upstream-artifact-handoff.bak")
    if not backup.exists():
        backup.write_text(original, encoding="utf-8")
    path.write_text(text, encoding="utf-8")

py_compile.compile(str(path), doraise=True)

required = [
    "upstream_artifact_dirs=upstream_artifact_dirs",
    'upstream_root = current_artifact_dir / "upstream"',
    "shutil.copytree(source_dir, target_dir)",
    'artifact_index.json',
    'vibe.upstream_artifact_index.v1',
    'evidence_bundle.json',
    'vibe.upstream_evidence_bundle.v1',
    marker,
]
current = path.read_text(encoding="utf-8")
missing = [item for item in required if item not in current]
if missing:
    raise SystemExit("VIBE_UPSTREAM_HANDOFF_VERIFY_FAILED:" + ",".join(missing))

print(f"CYGNUS_UPSTREAM_ARTIFACT_HANDOFF_FIX=PASS path={path}")
