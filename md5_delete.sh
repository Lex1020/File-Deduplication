#!/bin/bash
set -euo pipefail

# Determine available MD5 command (GNU coreutils `md5sum` or macOS `md5`).
if command -v md5sum >/dev/null 2>&1; then
  md5_cmd='md5sum'
elif command -v md5 >/dev/null 2>&1; then
  md5_cmd='md5 -r'
else
  echo "Error: neither 'md5sum' nor 'md5' command is available." >&2
  exit 1
fi

# Usage check: Ensure exactly one argument (directory) is provided.
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 /path/to/directory"
  exit 1
fi

# Validate that the argument is a directory.
if [ ! -d "$1" ]; then
  echo "Error: '$1' is not a valid directory."
  exit 1
fi

declare -A checksums

# Use process substitution instead of a pipe so that the associative array is not lost in a subshell.
while IFS= read -r -d '' file; do
  # Make sure it's a regular file (could be redundant with find's -type f).
  if [ -f "$file" ]; then
    # Calculate the MD5 checksum using awk for clarity.
    file_checksum=$($md5_cmd "$file" | awk '{print $1}')
    # If the checksum is already in the array, delete the duplicate.
    if [[ -n "${checksums[$file_checksum]:-}" ]]; then
      echo "Deleting duplicate file: $file"
      rm "$file"
    else
      # Store the checksum in the associative array.
      checksums["$file_checksum"]=1
    fi
  fi
done < <(find "$1" -type f -print0)
