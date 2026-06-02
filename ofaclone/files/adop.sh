#!/bin/bash

# Source profile files for environment setup
source ~/.bash_profile

if [ -f ~/.profile ]; then
  . ~/.profile
elif [ -f ~/.bash_profile ]; then
  echo ""
fi

# --- Parameter Validation ---
if [ -z "$1" ] || [ -z "$2" ]; then
  echo "❌ ERROR: Missing required parameters."
  echo "Usage: $0 <comma_separated_patch_list> <target_directory_for_patching> [force_option: Y/N]"
  echo "Example: $0 38298685,38261399 /u01/install/PATCH_TOP Y"
  exit 1
fi
# --- End Parameter Validation ---

# Assign command-line arguments to variables
PATCHLIST="$1"
TGT_DIR="$2"
FORCE_OPTION="${3:-N}" # Default to 'N' if not provided

# --- Password Prompts ---
read -s -p "Enter APPS password: " TGT_APPS_PWD
echo
read -s -p "Enter SYSTEM password: " TGT_SYSTEM_PWD
echo
read -s -p "Enter WebLogic password: " TGT_WBLG_PSWD
echo
# --- End Password Prompts ---


# Load the RUN environment (assuming the app_tgt_mount is already set or sourced elsewhere)
# NOTE: Using an assumption here as {{ app_tgt_mount }} is a template variable.
# For a runnable script, this should be a fixed path, e.g., /u01/app/fs1/EBSapps/appl
. /path/to/your/EBSapps.env RUN

# Change to the target directory for patching
cd "$TGT_DIR" || { echo "❌ ERROR: Cannot change directory to $TGT_DIR"; exit 1; }

# Split comma-separated list into an array (handles spaces around commas)
IFS=',' read -ra PATCHES <<< "$PATCHLIST"

echo "--- 🛠️ Pre-processing and unzipping patches ---"

for PATCH in "${PATCHES[@]}"; do
  # Trim whitespace
  PATCH=$(echo "$PATCH" | tr -d '[:space:]')
  [ -z "$PATCH" ] && continue

  # Unzip the patch
  if [ -d "$PATCH" ]; then
    echo "ℹ️ Patch $PATCH directory already exists in $TGT_DIR."
  else
    echo "Unzipping $PATCH ..."
    # Use a more robust unzip command targeting the current directory ($TGT_DIR)
    # Assuming patch zip file is named pXXXXXXXX.zip and located in $TGT_DIR
    rm -rf "$PATCH"
    if unzip -o "$TGT_DIR/p${PATCH}"*.zip -d "$TGT_DIR"; then
      echo "✅ Successfully unzipped p${PATCH}*.zip."
    else
      echo "❌ ERROR: unzip failed for p${PATCH}*.zip. Please check the file and permissions."; 
      exit 1;
    fi
  fi
done

echo "--- ✅ All patches unzipped. Starting adop cycle. ---"

# 1. Check if any of the patches are already applied
echo "Checking patch status for the list: $PATCHLIST..."
STATUS_FILE="/tmp/patch_status.lst"

# Building the SQL query dynamically is complex in a heredoc.
# A simple loop to check each patch is more straightforward for shell.
APPLIED_PATCHES=0
for PATCH in "${PATCHES[@]}"; do
  PATCH=$(echo "$PATCH" | tr -d '[:space:]')
  [ -z "$PATCH" ] && continue
  sqlplus -s apps/$PSWD <<SQL > "$STATUS_FILE"
set echo off feedback off heading off
select ad_patch.is_patch_applied('R12',-1,$PATCH) from dual;
exit
SQL
  STATUS=$(tail -1 "$STATUS_FILE" 2>/dev/null | tr -d '[:space:]')
  if [ "$STATUS" != "NOT_APPLIED" ]; then
    echo "ℹ️ Patch **$PATCH** is already applied (Status: $STATUS)."
    APPLIED_PATCHES=$((APPLIED_PATCHES + 1))
  fi
done
rm -f "$STATUS_FILE"

if [ ${#PATCHES[@]} -eq $APPLIED_PATCHES ]; then
    echo "All patches in the list are already applied. Exiting."
    exit 0
fi

# 2. Apply the patches
echo "Applying patches **$PATCHLIST** using adop..."
#. {{ app_tgt_mount }}/EBSapps.env RUN

if [ "$FORCE_OPTION" = "Y" ]; then
  echo "Running **hotpatch** apply phase for $PATCHLIST."
  adop phase=apply patches=$PATCHLIST patchtop="$TGT_DIR" workers=16 hotpatch=yes restart=yes <<EOF
$TGT_APPS_PWD
$TGT_SYSTEM_PWD
$TGT_WBLG_PSWD
EOF
else
  echo "Running **full cycle** (prepare, apply, finalize, cutover, cleanup) for $PATCHLIST."
  adop phase=prepare,apply,finalize,cutover,cleanup patches=$PATCHLIST patchtop="$TGT_DIR" workers=16 restart=yes <<EOF
$TGT_APPS_PWD
$TGT_SYSTEM_PWD
$TGT_WBLG_PSWD
EOF
fi

if [ $? -eq 0 ]; then
  echo "✅ Successfully completed adop cycle for patches **$PATCHLIST**."
else
  echo "❌ ERROR: adop phase failed for patches **$PATCHLIST**. Check log files."
fi

echo "--- ✅ Patching process complete ---"