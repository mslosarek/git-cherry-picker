#!/bin/bash

# Function to display an error and exit
function error_exit {
  echo "$1" >&2
  exit 1
}

# Function to display help message
function show_help {
  echo "Usage: $0 [OPTIONS]"
  echo "Batch cherry-pick commits between two git hashes"
  echo
  echo "Options:"
  echo "  -h          Show this help message"
  echo "  -c FILE     Specify CSV output file (default: \$BATCH_CHERRY_PICK_OUTPUT/cherrypick_progress.csv or ~/cherrypick_progress.csv)"
  echo "  -f          Continue from last successful commit in existing CSV file"
  echo "  -s HASH     Specify starting commit hash"
  echo "  -e HASH     Specify ending commit hash"
  exit 0
}

# Function to generate CSV filename from hashes
function generate_csv_filename {
  local start=$1
  local end=$2
  echo "${BATCH_CHERRY_PICK_OUTPUT:-$HOME}/cherrypick_${start:0:7}_${end:0:7}.csv"
}

# Set default CSV file or use environment variable or command line argument
csv_file="${BATCH_CHERRY_PICK_OUTPUT:-$HOME}/cherrypick_progress.csv"
continue_previous=false

# Parse command line arguments
while getopts "hc:f:s:e:" opt; do
  case $opt in
    h) show_help ;;
    c) csv_file="$OPTARG" ;;
    f) continue_previous=true ;;
    s) start_hash="$OPTARG" ;;
    e) end_hash="$OPTARG" ;;
    \?) echo "Usage: $0 [-h] [-c csv_file] [-f to continue] [-s start_hash] [-e end_hash]" >&2; exit 1 ;;
  esac
done

# Prompt for the starting hash if not provided
if [ -z "$start_hash" ]; then
  read -p "Enter the starting hash: " start_hash
fi

# Prompt for the ending hash if not provided
if [ -z "$end_hash" ]; then
  read -p "Enter the ending hash: " end_hash
fi

# Check if the provided hashes are valid
if ! git cat-file -e "$start_hash"^{commit} 2>/dev/null; then
  error_exit "Error: Starting hash $start_hash is not a valid commit."
fi

if ! git cat-file -e "$end_hash"^{commit} 2>/dev/null; then
  error_exit "Error: Ending hash $end_hash is not a valid commit."
fi

# Generate CSV filename if not specified via -c option
if [ "$csv_file" = "${BATCH_CHERRY_PICK_OUTPUT:-$HOME}/cherrypick_progress.csv" ]; then
  csv_file=$(generate_csv_filename "$start_hash" "$end_hash")
fi

# Check if file exists and continue from last successful commit
if [ -f "$csv_file" ]; then
  echo ""
  echo "Found existing progress file: $csv_file"
  last_processed=$(awk -F, '$2!="pending" && $1!="commit_hash" {last=$1} END {print last}' "$csv_file")
  if [ -n "$last_processed" ]; then
    echo "Continuing from last processed commit: $last_processed"
    start_hash=$last_processed
  fi
  continue_previous=true
else
  echo "Creating new progress file: $csv_file"
  echo "commit_hash,status,timestamp,commit_message" > "$csv_file"
fi

# Get the list of commits between the two hashes
commits=$(git rev-list --reverse "$start_hash".."$end_hash")

# Check if there are any commits to cherry-pick
if [ -z "$commits" ]; then
  error_exit "No commits found between $start_hash and $end_hash."
fi

# Write all commits to CSV with 'pending' status if not continuing from previous
if [ "$continue_previous" = false ]; then
  for commit in $commits; do
    commit_msg=$(git log --format=%s -n 1 "$commit" | sed 's/,/;/g')
    echo "$commit,pending,$(date '+%Y-%m-%d %H:%M:%S'),$commit_msg" >> "$csv_file"
  done
  echo "Written all commits to $csv_file with pending status."
fi

# Loop through the commits and cherry-pick each one
for commit in $commits; do
  echo ""
  echo "Cherry-picking commit $commit..."
  commit_msg=$(git log --format=%s -n 1 "$commit")
  echo "Commit message:"
  echo "$commit_msg"
  echo ""
  read -p "Do you want to cherry-pick this commit? (y/n/q, default: y): " choice
  choice=${choice:-y}

  case $choice in
    y|Y)
      if ! git cherry-pick "$commit"; then
        echo "Error while cherry-picking commit $commit. Please resolve the conflict and press Enter to continue."
        read -p "Press Enter to continue to the next commit..."
        status="conflict-resolved"
      else
        status="success"
      fi
      ;;
    n|N)
      echo "Skipping commit $commit"
      status="skipped"
      ;;
    q|Q)
      echo "Exiting cherry-pick process..."
      exit 0
      ;;
    *)
      echo "Invalid choice. Skipping commit."
      status="skipped"
      ;;
  esac

  # Record progress in CSV
  # Create temporary file
  temp_file=$(mktemp)
  commit_msg=$(git log --format=%s -n 1 "$commit" | sed 's/,/;/g')
  # Update existing row or add new one
  if grep -q "^$commit," "$csv_file"; then
    # Update the existing row
    awk -F, -v commit="$commit" -v status="$status" -v timestamp="$(date '+%Y-%m-%d %H:%M:%S')" -v msg="$commit_msg" \
      'BEGIN {OFS=","} $1==commit {$2=status; $3=timestamp; $4=msg} {print}' "$csv_file" > "$temp_file"
  else
    # Copy existing content and append new row
    cat "$csv_file" > "$temp_file"
    echo "$commit,$status,$(date '+%Y-%m-%d %H:%M:%S'),$commit_msg" >> "$temp_file"
  fi
  mv "$temp_file" "$csv_file"
  echo "Processed commit $commit with status: $status"

  if [ "$status" != "skipped" ]; then
    read -p "Press Enter to continue to the next commit..."
  fi
done

echo "All commits between $start_hash and $end_hash have been cherry-picked successfully."
