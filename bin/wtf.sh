#!/usr/bin/env bash
# Source this file or add it to your shell config:
# source ~/bin/dev-workflow-tools/bin/wtf.sh

wtf() {
  local CANONICAL="$HOME/work/repos/ul"
  
  # Files to seed on creation
  local FILES=(.env)
  
  # Run the main wtf script and capture the output
  local result
  result=$("$HOME/bin/dev-workflow-tools/bin/wtf-impl" "$@")
  local exit_code=$?
  
  # If the script outputs a worktree path, cd to it
  if [[ $exit_code -eq 0 ]] && [[ -n "$result" ]]; then
    echo "$result"
  fi
  
  return $exit_code
}
