#!/usr/bin/env bash
set -euo pipefail

bundle_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

usage() {
    cat <<'EOF'
Usage: bash MEGAS/run.sh --ds NAME [--threads N] [--keys N]
                          [--insert PCT] [--delete PCT] [--ms N]
                          [--prefill N] [--reclaimer NAME]
                          [-- extra SetBench arguments]

Run a binary previously compiled by MEGAS/microbench/Makefile.
EOF
}

nonnegative_integer() { [[ $1 =~ ^[0-9]+$ ]]; }
positive_integer() { nonnegative_integer "$1" && ((10#$1 > 0)); }

structure=
threads=4
keys=1000
insert=25
delete=25
milliseconds=1000
prefill=0
reclaimer=debra
extra=()

while (($#)); do
    case "$1" in
        --ds|--threads|--keys|--insert|--delete|--ms|--prefill|--reclaimer)
            (($# >= 2)) || { usage >&2; exit 2; }
            case "$1" in
                --ds) structure=$2 ;;
                --threads) threads=$2 ;;
                --keys) keys=$2 ;;
                --insert) insert=$2 ;;
                --delete) delete=$2 ;;
                --ms) milliseconds=$2 ;;
                --prefill) prefill=$2 ;;
                --reclaimer) reclaimer=$2 ;;
            esac
            shift 2
            ;;
        --)
            shift
            extra=("$@")
            break
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ $structure =~ ^[A-Za-z0-9_]+$ && $reclaimer =~ ^[A-Za-z0-9_]+$ ]] || {
    printf 'Specify a valid --ds NAME and --reclaimer NAME.\n' >&2
    exit 2
}
for number in "$threads" "$keys" "$milliseconds"; do
    positive_integer "$number" || {
        printf 'Threads, keys, and milliseconds must be positive integers.\n' >&2
        exit 2
    }
done
for number in "$insert" "$delete" "$prefill"; do
    nonnegative_integer "$number" || {
        printf 'Insert, delete, and prefill must be nonnegative integers.\n' >&2
        exit 2
    }
done
((10#$insert + 10#$delete <= 100)) || {
    printf 'Insert and delete percentages must total at most 100.\n' >&2
    exit 2
}

binary="$bundle_root/microbench/bin/$structure.$reclaimer"
[[ -x $binary ]] || {
    printf 'Binary not found: %s\nCompile it first using MEGAS/microbench/Makefile.\n' "$binary" >&2
    exit 1
}

cd -- "$bundle_root/microbench"
exec "$binary" -k "$keys" -i "$insert" -d "$delete" -t "$milliseconds" \
    -nwork "$threads" -nprefill "$prefill" "${extra[@]}"
