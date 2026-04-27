#!/bin/bash
# =============================================================================
# bootstrap.sh — serverdeploy stage runner
#
# Usage:
#   ./bootstrap.sh                       # run all stages in order
#   ./bootstrap.sh 10-caddy.sh           # run a single stage by name
#   ./bootstrap.sh --resume-from 20-databases.sh
#   ./bootstrap.sh --lock-ssh            # passes LOCK_SSH=1 to 00-base.sh
#                                          (removes port 22, must run with this
#                                           AFTER verifying port 2223 works)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

require_root

STAGES_DIR="${SCRIPT_DIR}/bootstrap"
[[ -d "${STAGES_DIR}" ]] || die "Stages dir not found: ${STAGES_DIR}"

LOCK_SSH=0
RESUME_FROM=""
SINGLE_STAGE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --lock-ssh)        LOCK_SSH=1; shift ;;
        --resume-from)     RESUME_FROM="$2"; shift 2 ;;
        --resume-from=*)   RESUME_FROM="${1#*=}"; shift ;;
        -h|--help)
            sed -n '2,15p' "$0"
            exit 0
            ;;
        -*)
            die "Unknown flag: $1"
            ;;
        *)
            if [[ -z "${SINGLE_STAGE}" ]]; then
                SINGLE_STAGE="$1"
                shift
            else
                die "Unexpected argument: $1"
            fi
            ;;
    esac
done

export LOCK_SSH

# Discover stages in lexical order
mapfile -t STAGES < <(find "${STAGES_DIR}" -maxdepth 1 -name '*.sh' -type f | sort)
[[ ${#STAGES[@]} -gt 0 ]] || die "No stages found in ${STAGES_DIR}"

run_stage() {
    local stage_path="$1"
    local stage_name
    stage_name="$(basename "${stage_path}")"
    info "═══ Running ${stage_name} ═══"
    bash "${stage_path}" || die "Stage failed: ${stage_name}"
    success "═══ ${stage_name} done ═══"
    echo
}

# Single-stage mode
if [[ -n "${SINGLE_STAGE}" ]]; then
    if [[ -f "${STAGES_DIR}/${SINGLE_STAGE}" ]]; then
        run_stage "${STAGES_DIR}/${SINGLE_STAGE}"
    elif [[ -f "${SINGLE_STAGE}" ]]; then
        run_stage "${SINGLE_STAGE}"
    else
        die "Stage not found: ${SINGLE_STAGE}"
    fi
    exit 0
fi

# All stages, optionally skipping until --resume-from
REACHED_RESUME=0
[[ -z "${RESUME_FROM}" ]] && REACHED_RESUME=1

for stage in "${STAGES[@]}"; do
    stage_name="$(basename "${stage}")"
    if [[ ${REACHED_RESUME} -eq 0 ]]; then
        if [[ "${stage_name}" == "${RESUME_FROM}" ]]; then
            REACHED_RESUME=1
        else
            info "Skipping ${stage_name} (--resume-from ${RESUME_FROM})"
            continue
        fi
    fi
    run_stage "${stage}"
done

success "All stages complete."
