#!/bin/bash
# This script takes a directory as an argument and deletes duplicate files based on md5 checksum
# Usage: bash md5_delete.sh /path/to/directory

declare -A arr
# Check if the argument is a valid directory
if [ -d "$1" ]; then
  # Find all the files in the directory and its subdirectories
  find "$1" -type f -print0 | while read -d $'\0' file
  do
    # Calculate the md5 checksum of each file
    md5=$(md5sum "$file" | cut -d ' ' -f 1)
    # Check if the checksum already exists in the associative array
    if [ -n "${arr[16#$md5]}" ]; then
      # If yes, delete the file as it is a duplicate
      echo "Deleting $file"
      rm "$file"
    else
      # If not, store the checksum in the array
      arr[16#$md5]=1
    fi
  done
else
  # If the argument is not a valid directory, print an error message
  echo "Invalid directory: $1"
  exit 1
fi

