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
    marker,
]
current = path.read_text(encoding="utf-8")
missing = [item for item in required if item not in current]
if missing:
    raise SystemExit("VIBE_UPSTREAM_HANDOFF_VERIFY_FAILED:" + ",".join(missing))

print(f"CYGNUS_UPSTREAM_ARTIFACT_HANDOFF_FIX=PASS path={path}")
