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
  echo "  -c FILE     Specify Markdown output file (default: \$BATCH_CHERRY_PICK_OUTPUT/cherrypick_progress.md or ~/cherrypick_progress.md)"
  echo "  -f          Continue from last successful commit in existing Markdown file"
  echo "  -s HASH     Specify starting commit hash"
  echo "  -e HASH     Specify ending commit hash"
  echo "  -a          Auto-continue cherry-picking until a conflict arises. Automatically checks if conflicts are resolved and continues without user input."
  exit 0
}

# Function to generate Markdown filename from hashes
function generate_md_filename {
  local start=$1
  local end=$2
  echo "${BATCH_CHERRY_PICK_OUTPUT:-$HOME}/cherrypick_${start:0:7}_${end:0:7}.md"
}

# Set default Markdown file or use environment variable or command line argument
md_file="${BATCH_CHERRY_PICK_OUTPUT:-$HOME}/cherrypick_progress.md"
continue_previous=false
auto_continue=false

# Parse command line arguments
while getopts "hc:f:s:e:a" opt; do
  case $opt in
    h) show_help ;;
    c) md_file="$OPTARG" ;;
    f) continue_previous=true ;;
    s) start_hash="$OPTARG" ;;
    e) end_hash="$OPTARG" ;;
    a) auto_continue=true ;;
    \?) echo "Usage: $0 [-h] [-c markdown_file] [-f to continue] [-s start_hash] [-e end_hash] [-a for auto-continue]" >&2; exit 1 ;;
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

# Generate Markdown filename if not specified via -c option
if [ "$md_file" = "${BATCH_CHERRY_PICK_OUTPUT:-$HOME}/cherrypick_progress.md" ]; then
  md_file=$(generate_md_filename "$start_hash" "$end_hash")
fi

# Check if file exists and continue from last successful commit
if [ -f "$md_file" ]; then
  echo ""
  echo "Found existing progress file: $md_file"
  last_processed=$(awk -F'|' '$2!="pending" && $1!="commit_hash" {last=$1} END {print last}' "$md_file")
  if [ -n "$last_processed" ]; then
    echo "Continuing from last processed commit: $last_processed"
    start_hash=$last_processed
  fi
  continue_previous=true
else
  echo "Creating new progress file: $md_file"
  # Initialize the commit data array
  declare -a commit_data
fi

# Get the list of commits between the two hashes
commits=$(git rev-list --reverse "$start_hash".."$end_hash")

# Check if there are any commits to cherry-pick
if [ -z "$commits" ]; then
  error_exit "No commits found between $start_hash and $end_hash."
fi

# Loop through the commits and cherry-pick each one
for commit in $commits; do
  echo ""
  echo "Cherry-picking commit $commit..."
  commit_msg=$(git log --format=%s -n 1 "$commit")
  echo "Commit message:"
  echo "$commit_msg"
  echo ""

  if [ "$auto_continue" = true ]; then
    # Auto-continue without prompting the user
    choice="y"
    echo "Auto-continue is enabled. Automatically choosing 'y' to cherry-pick this commit."
  else
    # If auto-continue is not set, ask the user for input
    read -p "Do you want to cherry-pick this commit? (y/n/q, default: y): " choice
    choice=${choice:-y}
  fi

  echo "Choice: $choice"  # Debugging output to verify the choice

  case $choice in
    y|Y)
      if ! git cherry-pick "$commit"; then
        echo "Conflict detected while cherry-picking commit $commit."
        if [ "$auto_continue" = true ]; then
          echo "Waiting for conflict resolution..."
          # Wait until conflict is resolved
          while git status | grep -q 'both modified'; do
            sleep 2  # Wait a little before checking again
          done
          echo "Conflict resolved. Continuing cherry-pick..."
          git cherry-pick --continue
        else
          echo "Please resolve the conflict manually, then press Enter to continue."
          read -p "Press Enter to continue to the next commit..."
        fi
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

  # Convert the commit hash to a Markdown link
  commit_link="[${commit}](https://github.com/prebid/Prebid.js/commit/${commit})"

  # Transform any PR number (e.g., #12379) in the commit message into a Markdown link.
  # This uses sed with a regular expression that matches '#' followed by one or more digits.
  pr_linked_message=$(echo "$commit_msg" | sed -E 's/#([0-9]+)/[#\1](https:\/\/github.com\/prebid\/Prebid.js\/pull\/\1)/g')

  # Store commit information in the array
  commit_data+=("$commit_link|$status|$(date '+%Y-%m-%d %H:%M:%S')|$pr_linked_message")
done

# Now that all commits are processed, generate the Markdown file
echo -e "| Commit Hash | Status | Timestamp | Commit Message |" > "$md_file"
echo -e "|-------------|--------|-----------|----------------|" >> "$md_file"
for entry in "${commit_data[@]}"; do
  echo "$entry" >> "$md_file"
done

echo "All commits between $start_hash and $end_hash have been cherry-picked successfully, and progress has been recorded in $md_file."
