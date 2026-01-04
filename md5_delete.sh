#!/bin/bash

# ==============================================================================
# Synology Smart Deduplicator (Hardlink Edition v5)
# ==============================================================================
# 
# FEATURES:
# 1. Interactive Mode Selection (Dry Run vs Live).
# 2. Progress bars for Scanning, Hashing, and Resolving.
# 3. Auto-resolves Priority folders.
# 4. Auto-resolves "Same Folder" duplicates (keeps shortest filename).
# 5. Verbose logging and Action Summary.
#
# ==============================================================================

# --- CONFIGURATION ---

# Set to true to automatically delete/link if a Priority folder is found.
# If false, it will just highlight the priority file but still ask you.
AUTO_RESOLVE=true

# List folders where originals should be kept.
# The script checks these in order.
PRIORITY_DIRS=( 
    "Documents/Important Docs"
)

# Synology specific exclusions
EXCLUDE_PATHS=( -not -path '*/@eaDir*' -not -path '*/#recycle*' -not -name '.DS_Store' )

# --- END CONFIGURATION ---

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ==============================================================================
# 0. MODE SELECTION
# ==============================================================================
clear
echo -e "${BLUE}========================================================${NC}"
echo -e "${BLUE}      Synology Deduplicator (Smart Hardlink Mode)${NC}"
echo -e "${BLUE}========================================================${NC}"
echo "Select execution mode:"
echo "  1) Dry Run (Default) - Only lists changes, touches nothing."
echo "  2) LIVE MODE         - DELETES duplicates and creates hardlinks."
echo ""
read -p "Enter choice [1]: " mode_choice

if [ "$mode_choice" == "2" ]; then
    echo -e "\n${RED}WARNING: LIVE MODE SELECTED.${NC}"
    echo "Files will be deleted and replaced with hardlinks."
    read -p "Type 'yes' to confirm: " confirm
    if [ "$confirm" == "yes" ]; then
        DRY_RUN=false
        MODE_STR="${RED}LIVE (Destructive)${NC}"
    else
        echo "Confirmation failed. Reverting to Dry Run."
        DRY_RUN=true
        MODE_STR="${YELLOW}DRY RUN (Safe)${NC}"
    fi
else
    DRY_RUN=true
    MODE_STR="${YELLOW}DRY RUN (Safe)${NC}"
fi

echo -e "Current Mode: $MODE_STR"
echo "Starting in 3 seconds..."
sleep 3

# ==============================================================================
# MAIN LOGIC
# ==============================================================================

TMP_DIR=$(mktemp -d)
RAW_LIST="$TMP_DIR/raw_scan.tmp"
SIZE_LIST="$TMP_DIR/sizes.txt"
HASH_LIST="$TMP_DIR/hashes.txt"
UNSORTED_HASH="$TMP_DIR/hashes_unsorted.txt"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Check for tools
command -v md5sum >/dev/null 2>&1 || { echo "Error: md5sum not found."; exit 1; }

echo "[1/4] Scanning files..."

# Run find in background to raw file so we can monitor progress
find . -type f "${EXCLUDE_PATHS[@]}" -printf "%s\t%p\t%i\0" > "$RAW_LIST" &
FIND_PID=$!

# Monitor loop
while kill -0 $FIND_PID 2>/dev/null; do
    # Count null bytes to get file count (fast)
    if [ -f "$RAW_LIST" ]; then
        count=$(tr -cd '\0' < "$RAW_LIST" | wc -c)
        echo -ne "      -> Scanned files: $count\r"
    fi
    sleep 1
done
wait $FIND_PID

# Final count
total_scanned=$(tr -cd '\0' < "$RAW_LIST" | wc -c)
echo -e "      -> Scanned files: $total_scanned (Complete)   "

echo "      -> Sorting file index (Grouping by size)..."
sort -z -n -k1 "$RAW_LIST" > "$SIZE_LIST"

echo "[2/4] Identifying candidates..."
# Filter for files that share a size and check Inodes
awk -v RS='\0' -v ORS='\0' -F'\t' '
    {
        size = $1
        inode = $3
        
        if (size == prev_size) {
            # Only consider them candidates if they are NOT the same physical file (different inodes)
            if (inode != prev_inode) {
                if (count == 1) print prev_line
                print $0
                count++
            }
        } else {
            count = 1
        }
        prev_size = size
        prev_inode = inode
        prev_line = $0
    }
' "$SIZE_LIST" > "$TMP_DIR/candidates.0"

if [ ! -s "$TMP_DIR/candidates.0" ]; then
    echo "No duplicates found."
    exit 0
fi

# Count candidates for the progress bar
candidate_count=$(tr -cd '\0' < "$TMP_DIR/candidates.0" | wc -c)
echo "[3/4] Hashing $candidate_count candidate files..."

# Hashing loop with progress indicator
count=0
cut -z -f2 "$TMP_DIR/candidates.0" | \
while IFS= read -r -d '' file; do
    md5sum "$file"
    ((++count))
    if (( count % 25 == 0 )); then
        echo -ne "      Progress: $count / $candidate_count\r" >&2
    fi
done > "$UNSORTED_HASH"

echo -e "      Progress: $candidate_count / $candidate_count (Sorting...)     " >&2
sort "$UNSORTED_HASH" > "$HASH_LIST"

echo "[4/4] Processing Duplicates..."

# Function to check if a file is in a priority dir
get_priority_score() {
    local file_path="$1"
    local score=999
    local i=0
    for dir in "${PRIORITY_DIRS[@]}"; do
        if [[ "$file_path" == *"/$dir/"* ]] || [[ "$file_path" == "./$dir/"* ]]; then
            score=$i
            break
        fi
        ((i++))
    done
    echo "$score"
}

# --- Core Processing Function ---
process_group() {
    # If group has fewer than 2 files, it's not a duplicate set
    if [ ${#group_files[@]} -lt 2 ]; then
        return
    fi

    local best_idx=-1
    local best_score=999
    
    # 1. Determine Winner based on Priority
    for i in "${!group_files[@]}"; do
        local score=$(get_priority_score "${group_files[$i]}")
        if [ "$score" -lt "$best_score" ]; then
            best_score=$score
            best_idx=$i
        elif [ "$score" -eq "$best_score" ] && [ "$best_score" -ne 999 ]; then
            best_idx=-1 
        fi
    done

    # 2. Tie-Breaker: Same Directory Check
    if [ "$best_idx" -eq -1 ]; then
         local first_dir=$(dirname "${group_files[0]}")
         local all_same_dir=true
         local shortest_len=${#group_files[0]}
         local shortest_idx=0
         
         for i in "${!group_files[@]}"; do
             local d=$(dirname "${group_files[i]}")
             if [ "$d" != "$first_dir" ]; then
                 all_same_dir=false
                 break
             fi
             
             if [ ${#group_files[i]} -lt $shortest_len ]; then
                 shortest_len=${#group_files[i]}
                 shortest_idx=$i
             fi
         done
         
         if [ "$all_same_dir" = true ]; then
             best_idx=$shortest_idx
         fi
    fi

    # 3. Decide Action
    if [ "$best_idx" -ne -1 ] && [ "$AUTO_RESOLVE" = true ]; then
        keep_file="${group_files[$best_idx]}"
        echo -e "${GREEN}[AUTO] Keeping: $keep_file${NC}"
        
        for i in "${!group_files[@]}"; do
            if [ "$i" -ne "$best_idx" ]; then
                del_file="${group_files[$i]}"
                if [ "$DRY_RUN" = true ]; then
                    echo "  [Dry Run] Would link: $del_file -> $keep_file"
                else
                    echo "  Linking: $del_file -> $keep_file"
                    ln -f "$keep_file" "$del_file" 2>/dev/null || { rm "$del_file" && ln "$keep_file" "$del_file"; }
                    ((total_linked++))
                fi
            fi
        done
    else
        # Interactive Mode
        echo -e "\n${YELLOW}--- Duplicate Set ($prev_hash) ---${NC}"
        for i in "${!group_files[@]}"; do
            local f="${group_files[$i]}"
            local score=$(get_priority_score "$f")
            local marker=" "
            if [ "$score" -ne 999 ]; then marker="*"; fi
            echo "  [$i]$marker $f"
        done
        
        echo "  [s] Skip"
        # Force reading from keyboard (FD 1) to avoid file loop conflict
        read -p "Keep which file? (Enter number): " choice <&1
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -lt "${#group_files[@]}" ]; then
            keep_file="${group_files[$choice]}"
            echo "Keeping: $keep_file"
            for i in "${!group_files[@]}"; do
                if [ "$i" -ne "$choice" ]; then
                    del_file="${group_files[$i]}"
                    if [ "$DRY_RUN" = true ]; then
                        echo "  (Dry) Would hardlink: $del_file -> $keep_file"
                    else
                        echo "  Linking: $del_file -> $keep_file"
                        ln -f "$keep_file" "$del_file" 2>/dev/null || { rm "$del_file" && ln "$keep_file" "$del_file"; }
                        ((total_linked++))
                    fi
                fi
            done
        else
            echo "Skipping group."
        fi
    fi
}
# --- End Function ---

# Variables for loop
prev_hash=""
declare -a group_files
total_lines=$(wc -l < "$HASH_LIST")
current_line=0
total_linked=0

# FIX: We read from File Descriptor 3 (<&3) so stdin (keyboard) stays free for the interactive prompt
while IFS= read -u 3 -r line; do
    ((current_line++))
    hash="${line%%  *}"
    
    # Parsing Fix: Handle 1 or 2 spaces, and * for binary mode
    file="${line#* }"   # Remove hash and first separator char
    file="${file# }"    # Remove second space if present
    file="${file#\*}"   # Remove asterisk if present
    
    if [ "$hash" == "$prev_hash" ]; then
        group_files+=("$file")
    else
        # Process previous group
        process_group
        
        # Show progress
        if (( current_line % 50 == 0 )); then
                 echo -ne "      Resolving... $current_line / $total_lines lines processed\r" >&2
        fi
        
        # Reset
        prev_hash="$hash"
        group_files=("$file")
    fi
done 3< "$HASH_LIST"

# CRITICAL FIX: Process the very last group collected in the loop
process_group

# Close FD 3
exec 3<&-

echo ""
echo "========================================================"
echo "Deduplication Complete."
if [ "$DRY_RUN" = false ]; then
    echo "Total files successfully replaced with hardlinks: $total_linked"
else
    echo "Dry Run Complete. No files were modified."
fi
echo "========================================================"
