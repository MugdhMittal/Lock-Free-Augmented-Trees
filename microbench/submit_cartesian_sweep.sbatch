#!/usr/bin/env bash
# One task for fixed-size variants and one task for each requested array size.
# At most two tasks run concurrently, matching the medium queue's per-user
# running-job limit.

#SBATCH --job-name=lft-sweep
#SBATCH --partition=medium
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=128
#SBATCH --array=0-11%2
#SBATCH --time=6-23:00:00
#SBATCH --output=slurm-sweep-%A_%a.out
#SBATCH --error=slurm-sweep-%A_%a.err

set -euo pipefail

ARRAY_SIZES=(1 5 10 25 50 100 200 500 1000 2000 4000)
TASK_ID="${SLURM_ARRAY_TASK_ID:?Slurm array task ID is required}"

if (( TASK_ID == 0 )); then
  TASK_MODE=fixed
else
  TASK_MODE="${ARRAY_SIZES[$((TASK_ID - 1))]}"
fi

module purge
module load gromacs/2023.2
module load GCC/10.2.0

cd "$HOME/LFT/setbench/microbench"

# All tasks share this campaign directory while retaining task-specific CSVs
# and raw logs. Override at submission with:
#   sbatch --export=ALL,CAMPAIGN_ID=my-descriptive-name submit_cartesian_sweep.sbatch
export CAMPAIGN_ID="${CAMPAIGN_ID:-campaign-${SLURM_ARRAY_JOB_ID}}"

srun --cpu-bind=cores bash ./run_cartesian_sweep.sh "${TASK_MODE}"
