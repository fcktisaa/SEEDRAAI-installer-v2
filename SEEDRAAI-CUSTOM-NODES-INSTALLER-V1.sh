#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="1.0.0"
BUILD="verified-bundle-2026-08-08"
COMFY_DIR="${COMFY_DIR:-}"
HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
REPO_ID="${SEEDRA_CUSTOM_NODES_REPO_ID:-${SEEDRA_REPO_ID:-SEEDRAAI/SEEDRAAI}}"
REVISION="${SEEDRA_CUSTOM_NODES_REVISION:-${SEEDRA_REVISION:-main}}"
ARCHIVE_FILE="${SEEDRA_CUSTOM_NODES_FILE:-SEEDRAAI_CustomNodes_2026-08-08.tar.gz}"
ARCHIVE_SHA256="${SEEDRA_CUSTOM_NODES_SHA256:-a9d7e5247f46229e7658172886a32be141c9ff68b677b3f43e6206325fe9df8c}"
EXPECTED_FILES="${SEEDRA_CUSTOM_NODES_EXPECTED_FILES:-6405}"
EXPECTED_UNPACKED_BYTES="${SEEDRA_CUSTOM_NODES_UNPACKED_BYTES:-2372538131}"
LOCAL_ARCHIVE="${SEEDRA_CUSTOM_NODES_LOCAL:-}"
STORE_DIR="${SEEDRA_STORE_DIR:-}"
SKIP_DEPS="${SEEDRA_SKIP_NODE_DEPS:-0}"
SKIP_VERIFY="${SEEDRA_SKIP_NODE_VERIFY:-0}"
DEPS_STRICT="${SEEDRA_NODE_DEPS_STRICT:-1}"
KEEP_BACKUP="${SEEDRA_KEEP_NODE_BACKUP:-0}"
DRY_RUN=0

usage() {
  cat <<'USAGE'
SEEDRAAI verified custom-node bundle installer

Usage:
  HF_TOKEN=hf_xxx bash SEEDRAAI-CUSTOM-NODES-INSTALLER-V1.sh [options]

Options:
  --hf-token TOKEN       Hugging Face read token
  --comfy-dir PATH       Path to ComfyUI (auto-detected by default)
  --revision REV         Custom-node archive repository revision
  --nodes-repo REPO      Repository containing the archive
  --nodes-file FILE      Archive filename in the repository
  --nodes-archive PATH   Use a local archive instead of downloading
  --skip-node-deps       Do not install Python dependencies
  --skip-node-verify     Do not run the ComfyUI import test
  --node-deps-best-effort
                         Continue after dependency installation failures
  --keep-node-backup     Keep replaced node folders after successful verification
  --dry-run              Show the plan without changing files
  -h, --help             Show help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hf-token)
      [[ $# -ge 2 ]] || { echo "Error: --hf-token requires a value." >&2; exit 2; }
      HF_TOKEN="$2"; shift 2 ;;
    --hf-token=*) HF_TOKEN="${1#*=}"; shift ;;
    --comfy-dir)
      [[ $# -ge 2 ]] || { echo "Error: --comfy-dir requires a value." >&2; exit 2; }
      COMFY_DIR="$2"; shift 2 ;;
    --comfy-dir=*) COMFY_DIR="${1#*=}"; shift ;;
    --revision)
      [[ $# -ge 2 ]] || { echo "Error: --revision requires a value." >&2; exit 2; }
      REVISION="$2"; shift 2 ;;
    --revision=*) REVISION="${1#*=}"; shift ;;
    --nodes-repo)
      [[ $# -ge 2 ]] || { echo "Error: --nodes-repo requires a value." >&2; exit 2; }
      REPO_ID="$2"; shift 2 ;;
    --nodes-repo=*) REPO_ID="${1#*=}"; shift ;;
    --nodes-file)
      [[ $# -ge 2 ]] || { echo "Error: --nodes-file requires a value." >&2; exit 2; }
      ARCHIVE_FILE="$2"; shift 2 ;;
    --nodes-file=*) ARCHIVE_FILE="${1#*=}"; shift ;;
    --nodes-archive)
      [[ $# -ge 2 ]] || { echo "Error: --nodes-archive requires a value." >&2; exit 2; }
      LOCAL_ARCHIVE="$2"; shift 2 ;;
    --nodes-archive=*) LOCAL_ARCHIVE="${1#*=}"; shift ;;
    --skip-node-deps) SKIP_DEPS=1; shift ;;
    --skip-node-verify) SKIP_VERIFY=1; shift ;;
    --node-deps-best-effort) DEPS_STRICT=0; shift ;;
    --keep-node-backup) KEEP_BACKUP=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for value in "$SKIP_DEPS" "$SKIP_VERIFY" "$DEPS_STRICT" "$KEEP_BACKUP"; do
  [[ "$value" == "0" || "$value" == "1" ]] || {
    echo "Error: boolean environment values must be 0 or 1." >&2
    exit 2
  }
done
[[ "$EXPECTED_FILES" =~ ^[1-9][0-9]*$ ]] || { echo "Error: expected file count must be positive." >&2; exit 2; }
[[ "$EXPECTED_UNPACKED_BYTES" =~ ^[1-9][0-9]*$ ]] || { echo "Error: expected unpacked bytes must be positive." >&2; exit 2; }
[[ "$ARCHIVE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "Error: invalid custom-node SHA-256." >&2; exit 2; }
ARCHIVE_SHA256="${ARCHIVE_SHA256,,}"

find_comfy() {
  local candidates=(
    "/workspace/ComfyUI"
    "/workspace/madapps/ComfyUI"
    "/root/ComfyUI"
    "/opt/ComfyUI"
    "/ComfyUI"
    "$PWD/ComfyUI"
    "$PWD"
  )
  local d
  for d in "${candidates[@]}"; do
    if [[ -f "$d/main.py" && -d "$d/models" ]]; then
      printf '%s\n' "$d"
      return 0
    fi
  done
  return 1
}

find_comfy_python() {
  if [[ -n "${COMFY_PYTHON:-}" && -x "${COMFY_PYTHON}" ]]; then
    printf '%s\n' "$COMFY_PYTHON"
    return 0
  fi
  local p
  local candidates=(
    "$COMFY_DIR/.venv/bin/python"
    "$COMFY_DIR/venv/bin/python"
    "/workspace/venv/bin/python"
    "$COMFY_DIR/../python_embeded/python.exe"
    "$COMFY_DIR/../python_embeded/python"
    "$COMFY_DIR/python_embeded/python.exe"
    "$COMFY_DIR/python_embeded/python"
  )
  for p in "${candidates[@]}"; do
    if [[ -x "$p" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  command -v python3 || command -v python || return 1
}

if [[ -z "$COMFY_DIR" ]]; then
  COMFY_DIR="$(find_comfy || true)"
fi
if [[ -z "$COMFY_DIR" || ! -f "$COMFY_DIR/main.py" ]]; then
  echo "Error: ComfyUI was not found. Use --comfy-dir /path/to/ComfyUI." >&2
  exit 1
fi
COMFY_DIR="$(cd "$COMFY_DIR" && pwd)"
STORE_DIR="${STORE_DIR:-$COMFY_DIR/.seedraai_repository}"
PENDING_BACKUP_FILE="$STORE_DIR/pending-node-backup.txt"

PYTHON_BIN="$(find_comfy_python || true)"
if [[ -z "$PYTHON_BIN" ]]; then
  echo "Error: ComfyUI Python was not found." >&2
  exit 1
fi

if [[ "$DRY_RUN" != "1" ]]; then
  mkdir -p "$STORE_DIR/logs" "$STORE_DIR/packages" "$STORE_DIR/node-backups" "$COMFY_DIR/custom_nodes"
  LOG_FILE="$STORE_DIR/logs/custom-nodes-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG_FILE") 2>&1
else
  LOG_FILE=""
fi

report_exit() {
  local rc=$?
  if [[ "$rc" -ne 0 && -f "$PENDING_BACKUP_FILE" ]]; then
    echo "SAFE: previous matching custom-node folders were retained at:" >&2
    head -n 1 "$PENDING_BACKUP_FILE" >&2 || true
  fi
  return "$rc"
}
trap report_exit EXIT

printf '\n=======================================================\n'
printf ' SEEDRAAI custom-node installer v%s [%s]\n' "$VERSION" "$BUILD"
printf ' ComfyUI      : %s\n' "$COMFY_DIR"
printf ' Python       : %s\n' "$PYTHON_BIN"
if [[ -n "$LOCAL_ARCHIVE" ]]; then
  printf ' Node archive : %s\n' "$LOCAL_ARCHIVE"
else
  printf ' Node archive : %s @ %s / %s\n' "$REPO_ID" "$REVISION" "$ARCHIVE_FILE"
fi
printf ' SHA-256      : %s\n' "$ARCHIVE_SHA256"
printf ' Dependencies : %s\n' "$([[ "$SKIP_DEPS" == "1" ]] && echo skipped || ([[ "$DEPS_STRICT" == "1" ]] && echo strict || echo best-effort))"
printf ' Import test  : %s\n' "$([[ "$SKIP_VERIFY" == "1" ]] && echo skipped || echo enabled)"
printf '=======================================================\n\n'

if [[ "$DRY_RUN" == "1" ]]; then
  echo "[1/4] Dry run: archive acquisition skipped."
  echo "[2/4] Would verify SHA-256, path safety, payload size and $EXPECTED_FILES files."
  echo "[3/4] Would transactionally replace matching node folders and preserve unrelated nodes."
  echo "[4/4] Would install local requirements and run ComfyUI --quick-test-for-ci."
  echo "Dry run complete. Nothing was changed."
  exit 0
fi

if [[ -n "$LOCAL_ARCHIVE" ]]; then
  [[ -f "$LOCAL_ARCHIVE" ]] || { echo "Error: local archive does not exist: $LOCAL_ARCHIVE" >&2; exit 1; }
  ARCHIVE_PATH="$(cd "$(dirname "$LOCAL_ARCHIVE")" && pwd)/$(basename "$LOCAL_ARCHIVE")"
  echo "[1/4] Using local custom-node archive."
else
  [[ -n "$HF_TOKEN" ]] || { echo "Error: HF_TOKEN is required to download $REPO_ID/$ARCHIVE_FILE." >&2; exit 1; }
  if ! "$PYTHON_BIN" -c 'import huggingface_hub, hf_xet' >/dev/null 2>&1; then
    echo "[1/4] Installing Hugging Face downloader..."
    if ! "$PYTHON_BIN" -m pip install -q -U 'huggingface_hub[hf_xet]'; then
      "$PYTHON_BIN" -m pip install -q -U --break-system-packages 'huggingface_hub[hf_xet]'
    fi
  else
    echo "[1/4] Hugging Face downloader is ready."
  fi
  export HF_TOKEN SEEDRA_CUSTOM_NODES_REPO_ID="$REPO_ID" SEEDRA_CUSTOM_NODES_REVISION="$REVISION"
  export SEEDRA_CUSTOM_NODES_FILE="$ARCHIVE_FILE" SEEDRA_NODE_PACKAGE_DIR="$STORE_DIR/packages"
  export HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}"
  export HF_XET_CHUNK_CACHE_SIZE_BYTES="${HF_XET_CHUNK_CACHE_SIZE_BYTES:-0}"
  ARCHIVE_PATH="$("$PYTHON_BIN" - <<'PYDOWNLOAD'
import os
from huggingface_hub import hf_hub_download

path = hf_hub_download(
    repo_id=os.environ["SEEDRA_CUSTOM_NODES_REPO_ID"],
    revision=os.environ["SEEDRA_CUSTOM_NODES_REVISION"],
    filename=os.environ["SEEDRA_CUSTOM_NODES_FILE"],
    local_dir=os.environ["SEEDRA_NODE_PACKAGE_DIR"],
    token=os.environ.get("HF_TOKEN") or None,
)
print(path)
PYDOWNLOAD
)"
fi

export SEEDRA_NODE_ARCHIVE_PATH="$ARCHIVE_PATH"
export SEEDRA_NODE_ARCHIVE_SHA256="$ARCHIVE_SHA256"
export SEEDRA_NODE_EXPECTED_FILES="$EXPECTED_FILES"
export SEEDRA_NODE_EXPECTED_BYTES="$EXPECTED_UNPACKED_BYTES"
export SEEDRA_NODE_COMFY_DIR="$COMFY_DIR"
export SEEDRA_NODE_STORE_DIR="$STORE_DIR"
export SEEDRA_NODE_PENDING_BACKUP_FILE="$PENDING_BACKUP_FILE"

echo "[2/4] Verifying and transactionally installing the custom-node payload..."
"$PYTHON_BIN" - <<'PYINSTALL'
from __future__ import annotations

import hashlib
import json
import os
import shutil
import tarfile
import time
from pathlib import Path, PurePosixPath

archive = Path(os.environ["SEEDRA_NODE_ARCHIVE_PATH"]).resolve()
expected_hash = os.environ["SEEDRA_NODE_ARCHIVE_SHA256"].lower()
expected_files = int(os.environ["SEEDRA_NODE_EXPECTED_FILES"])
expected_bytes = int(os.environ["SEEDRA_NODE_EXPECTED_BYTES"])
comfy = Path(os.environ["SEEDRA_NODE_COMFY_DIR"]).resolve()
store = Path(os.environ["SEEDRA_NODE_STORE_DIR"]).resolve()
pending_file = Path(os.environ["SEEDRA_NODE_PENDING_BACKUP_FILE"])
target = comfy / "custom_nodes"

h = hashlib.sha256()
with archive.open("rb") as handle:
    for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
        h.update(chunk)
actual_hash = h.hexdigest()
if actual_hash != expected_hash:
    raise SystemExit(f"Archive SHA-256 mismatch: got {actual_hash}, expected {expected_hash}")
print(f"  OK   SHA-256 {actual_hash}")

with tarfile.open(archive, "r:gz") as tf:
    members = tf.getmembers()
    files = [m for m in members if m.isfile()]
    payload_bytes = sum(m.size for m in files)
    if len(files) != expected_files:
        raise SystemExit(f"Archive file count mismatch: got {len(files)}, expected {expected_files}")
    if payload_bytes != expected_bytes:
        raise SystemExit(f"Archive payload size mismatch: got {payload_bytes}, expected {expected_bytes}")

    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != "custom_nodes":
            raise SystemExit(f"Unsafe archive path: {member.name}")
        if member.issym() or member.islnk() or not (member.isfile() or member.isdir()):
            raise SystemExit(f"Unsupported archive entry type: {member.name}")

    free = shutil.disk_usage(store).free
    reserve = 1024**3
    if free < payload_bytes + reserve:
        need = (payload_bytes + reserve - free) / 1024**3
        raise SystemExit(f"Insufficient staging space; add at least {need:.1f} GiB")

    stage = store / "staging" / f"custom-nodes-{actual_hash[:12]}-{os.getpid()}"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    try:
        tf.extractall(stage, filter="fully_trusted")
    except TypeError:  # Python < 3.12
        tf.extractall(stage)

payload = stage / "custom_nodes"
critical = {
    "comfyui-manager",
    "comfyui-impact-pack",
    "comfyui-kjnodes",
    "comfyui_ipadapter_plus",
    "ComfyUI-VideoHelperSuite",
    "was-node-suite-comfyui",
    "ComfyUI-WanVideoWrapper",
    "comfyui_controlnet_aux",
    "comfyui-frame-interpolation",
}
present = {p.name for p in payload.iterdir()}
missing = sorted(critical - present)
if missing:
    shutil.rmtree(stage, ignore_errors=True)
    raise SystemExit("Archive is missing critical node directories: " + ", ".join(missing))

source_entries = sorted(payload.iterdir(), key=lambda p: p.name.casefold())
casefolded: dict[str, str] = {}
for entry in source_entries:
    old = casefolded.setdefault(entry.name.casefold(), entry.name)
    if old != entry.name:
        raise SystemExit(f"Case-colliding package entries: {old!r} and {entry.name!r}")

target.mkdir(parents=True, exist_ok=True)
backup = store / "node-backups" / time.strftime("custom-nodes-%Y%m%d-%H%M%S")
suffix = 0
while backup.exists():
    suffix += 1
    backup = backup.with_name(backup.name + f"-{suffix}")
backup.mkdir(parents=True)

displaced: list[tuple[Path, Path]] = []
installed: list[Path] = []
try:
    for source in source_entries:
        conflicts = [p for p in target.iterdir() if p.name.casefold() == source.name.casefold()]
        for index, destination in enumerate(conflicts):
            backup_name = destination.name if index == 0 else f"{destination.name}.case-conflict-{index}"
            backup_destination = backup / backup_name
            os.replace(destination, backup_destination)
            displaced.append((backup_destination, destination))

        destination = target / source.name
        os.replace(source, destination)
        installed.append(destination)
except Exception:
    for destination in reversed(installed):
        if destination.is_dir() and not destination.is_symlink():
            shutil.rmtree(destination, ignore_errors=True)
        else:
            destination.unlink(missing_ok=True)
    for backup_source, original_destination in reversed(displaced):
        if backup_source.exists() or backup_source.is_symlink():
            os.replace(backup_source, original_destination)
    shutil.rmtree(stage, ignore_errors=True)
    raise

shutil.rmtree(stage, ignore_errors=True)
marker = target / ".seedraai-custom-nodes.json"
marker.write_text(
    json.dumps(
        {
            "schemaVersion": 1,
            "archive": archive.name,
            "sha256": actual_hash,
            "fileCount": len(files),
            "payloadBytes": payload_bytes,
            "installedTopLevelEntries": [p.name for p in source_entries],
            "installedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        },
        indent=2,
    ) + "\n",
    encoding="utf-8",
)

if displaced:
    pending_file.write_text(str(backup) + "\n", encoding="utf-8")
else:
    shutil.rmtree(backup, ignore_errors=True)
    pending_file.unlink(missing_ok=True)
print(f"  OK   installed {len(files)} files in {len(source_entries)} top-level entries")
print(f"  OK   payload size {payload_bytes} bytes")
if displaced:
    print(f"  SAFE previous matching entries staged at {backup}")
PYINSTALL

pip_install() {
  if ! "$PYTHON_BIN" -m pip install --disable-pip-version-check -q "$@"; then
    "$PYTHON_BIN" -m pip install --disable-pip-version-check -q --break-system-packages "$@"
  fi
}

if [[ "$SKIP_DEPS" == "1" ]]; then
  echo "[3/4] Python dependency installation skipped."
else
  echo "[3/4] Installing dependencies from the extracted node folders..."
  export SEEDRA_NODE_DEPS_ROOT="$COMFY_DIR/custom_nodes"
  export SEEDRA_NODE_DEPS_STRICT="$DEPS_STRICT"
  "$PYTHON_BIN" - <<'PYDEPS'
from __future__ import annotations

import importlib.util
import os
import re
import subprocess
import sys
from pathlib import Path

root = Path(os.environ["SEEDRA_NODE_DEPS_ROOT"])
strict = os.environ.get("SEEDRA_NODE_DEPS_STRICT", "1") == "1"
plan_only = os.environ.get("SEEDRA_NODE_DEPS_PLAN", "0") == "1"
skip_names = {"torch", "torchvision", "torchaudio"}
opencv_seen = False
onnx_seen = False
groups: list[tuple[str, list[str]]] = []

def normalized_name(line: str) -> str:
    match = re.match(r"^([A-Za-z0-9_.-]+)", line)
    return match.group(1).lower().replace("_", "-") if match else ""

for node in sorted((p for p in root.iterdir() if p.is_dir()), key=lambda p: p.name.casefold()):
    requirement_files = [node / "requirements.txt"]
    if node.name.casefold() == "comfyui-frame-interpolation":
        requirement_files.append(node / "requirements-no-cupy.txt")
    requirements: list[str] = []
    seen: set[str] = set()
    for req_file in requirement_files:
        if not req_file.is_file():
            continue
        for raw in req_file.read_text(encoding="utf-8-sig", errors="replace").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            name = normalized_name(line)
            if name in skip_names:
                continue
            if name.startswith("opencv-python") or name.startswith("opencv-contrib-python"):
                opencv_seen = True
                continue
            if name in {"onnxruntime", "onnxruntime-gpu"}:
                onnx_seen = True
                continue
            key = line.casefold()
            if key not in seen:
                seen.add(key)
                requirements.append(line)
    if requirements:
        groups.append((node.name, requirements))

def pip_install(label: str, requirements: list[str]) -> bool:
    if plan_only:
        print(f"  PLAN {label} ({len(requirements)})")
        return True
    command = [sys.executable, "-m", "pip", "install", "--disable-pip-version-check", "-q", *requirements]
    print(f"  DEPS {label} ({len(requirements)})", flush=True)
    result = subprocess.run(command)
    if result.returncode == 0:
        return True
    retry = command[:4] + ["--break-system-packages"] + command[4:]
    return subprocess.run(retry).returncode == 0

failures: list[str] = []
if opencv_seen and not pip_install("shared/opencv", ["opencv-contrib-python-headless"]):
    failures.append("shared/opencv")

if onnx_seen:
    gpu = False
    try:
        import torch
        gpu = bool(torch.version.cuda)
    except Exception:
        pass
    onnx_package = "onnxruntime-gpu" if gpu else "onnxruntime"
    if not pip_install("shared/onnxruntime", [onnx_package]):
        failures.append("shared/onnxruntime")

for label, requirements in groups:
    if not pip_install(label, requirements):
        failures.append(label)

if importlib.util.find_spec("cupy") is None:
    cuda_major = None
    try:
        import torch
        if torch.version.cuda:
            cuda_major = int(torch.version.cuda.split(".", 1)[0])
    except Exception:
        pass
    cupy_package = "cupy-cuda12x" if cuda_major and cuda_major >= 12 else "cupy-cuda11x" if cuda_major == 11 else None
    if cupy_package and not pip_install("shared/cupy", [cupy_package]):
        failures.append("shared/cupy")
    elif not cupy_package:
        print("  NOTE CuPy skipped because no supported CUDA runtime was detected")

if failures:
    print("Dependency failures:", file=sys.stderr)
    for name in failures:
        print(f"  - {name}", file=sys.stderr)
    if strict:
        raise SystemExit(1)
    print("Continuing because best-effort mode was selected.", file=sys.stderr)
else:
    print(f"  OK   dependency groups installed: {len(groups)}")
PYDEPS

  echo "  Running pip consistency report..."
  "$PYTHON_BIN" -m pip check || echo "  WARN pip check reported environment conflicts; import verification will decide the result."
fi

if [[ "$SKIP_VERIFY" == "1" ]]; then
  echo "[4/4] ComfyUI custom-node import verification skipped."
else
  echo "[4/4] Running ComfyUI custom-node import verification..."
  VERIFY_LOG="$STORE_DIR/logs/custom-nodes-import-$(date +%Y%m%d-%H%M%S).log"
  export SEEDRA_NODE_VERIFY_LOG="$VERIFY_LOG"
  export SEEDRA_NODE_VERIFY_COMFY="$COMFY_DIR"
  "$PYTHON_BIN" - <<'PYVERIFY'
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

comfy = Path(os.environ["SEEDRA_NODE_VERIFY_COMFY"])
log_path = Path(os.environ["SEEDRA_NODE_VERIFY_LOG"])
command = [sys.executable, str(comfy / "main.py"), "--quick-test-for-ci", "--disable-auto-launch"]
try:
    result = subprocess.run(command, cwd=comfy, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
    output = result.stdout.decode("utf-8", errors="replace")
except subprocess.TimeoutExpired as exc:
    output = (exc.stdout or b"").decode("utf-8", errors="replace")
    log_path.write_text(output, encoding="utf-8")
    print(output)
    raise SystemExit("ComfyUI import verification timed out after 300 seconds")

log_path.write_text(output, encoding="utf-8")
print(output)
failed_imports = [line.strip() for line in output.splitlines() if re.search(r"\(IMPORT FAILED\)|cannot import custom node", line, re.I)]
if result.returncode != 0:
    raise SystemExit(f"ComfyUI import verification exited with code {result.returncode}; log: {log_path}")
if failed_imports:
    print("Custom-node import failures:", file=sys.stderr)
    for line in failed_imports:
        print(f"  - {line}", file=sys.stderr)
    raise SystemExit(f"Custom-node import verification failed; log: {log_path}")
print(f"  OK   ComfyUI quick import test passed; log: {log_path}")
PYVERIFY
fi

if [[ -f "$PENDING_BACKUP_FILE" ]]; then
  BACKUP_PATH="$(head -n 1 "$PENDING_BACKUP_FILE")"
  if [[ "$KEEP_BACKUP" == "1" ]]; then
    echo "Previous matching node folders kept at: $BACKUP_PATH"
  else
    export SEEDRA_NODE_BACKUP_TO_DELETE="$BACKUP_PATH"
    export SEEDRA_NODE_BACKUP_ROOT="$STORE_DIR/node-backups"
    "$PYTHON_BIN" - <<'PYCLEANUP'
import os
import shutil
from pathlib import Path

backup = Path(os.environ["SEEDRA_NODE_BACKUP_TO_DELETE"]).resolve()
root = Path(os.environ["SEEDRA_NODE_BACKUP_ROOT"]).resolve()
if backup.parent != root:
    raise SystemExit(f"Refusing to remove backup outside {root}: {backup}")
shutil.rmtree(backup)
PYCLEANUP
    rm -f "$PENDING_BACKUP_FILE"
    echo "Previous matching node backup removed after successful verification."
  fi
fi

echo
echo "Custom-node bundle installation complete."
echo "Log saved to: $LOG_FILE"
