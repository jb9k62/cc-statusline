#!/usr/bin/env bash
# Claude Code status line. Reads session JSON on stdin, prints two lines.
#   line 1: model · effort · repo/worktree · branch · PR
#   line 2: context bar · 5h limit · weekly limit · cost
# The │ inside a limit bar marks even-consumption pace: bar past the marker
# means you are burning the window faster than the clock.

input=$(cat)

# One field per line, read via process substitution: no temp file (bash here-docs
# need one) and safe for values containing spaces. bash 3.2 has no mapfile.
F=()
while IFS= read -r line; do F+=("$line"); done < <(
  printf '%s' "$input" | jq -r '
    def n(x): (x // 0) | floor;
    [ (.model.display_name // "?"),
      (.effort.level // "-"),
      (if .fast_mode then "1" else "0" end),
      n(.context_window.used_percentage),
      n(.context_window.total_input_tokens),
      n(.context_window.total_output_tokens),
      (.context_window.context_window_size // 200000),
      (.rate_limits.five_hour.used_percentage // -1 | floor),
      (.rate_limits.five_hour.resets_at // 0),
      (.rate_limits.seven_day.used_percentage // -1 | floor),
      (.rate_limits.seven_day.resets_at // 0),
      (.cost.total_cost_usd // 0),
      n(.cost.total_lines_added),
      n(.cost.total_lines_removed),
      (.workspace.current_dir // .cwd // "."),
      (.workspace.git_worktree // .worktree.name // "-"),
      (.workspace.repo.name // "-"),
      (.pr.number // 0),
      (.pr.review_state // "-"),
      (.agent.name // "-")
    ] | .[]'
)

MODEL=${F[0]}     EFFORT=${F[1]}     FAST=${F[2]}      CTX_PCT=${F[3]}
CTX_IN=${F[4]}    CTX_OUT=${F[5]}    CTX_SIZE=${F[6]}
FIVE_PCT=${F[7]}  FIVE_RESET=${F[8]} WK_PCT=${F[9]}    WK_RESET=${F[10]}
COST=${F[11]}     ADDED=${F[12]}     REMOVED=${F[13]}  CUR_DIR=${F[14]}
WORKTREE=${F[15]} REPO=${F[16]}      PR_NUM=${F[17]}   PR_STATE=${F[18]}
AGENT=${F[19]}

# jq missing or malformed input: emit a minimal line rather than a broken one
if [[ -z ${F[0]} ]]; then
  printf '%s\n' "$(printf '%s' "$input" | sed -n 's/.*"display_name":"\([^"]*\)".*/\1/p')"
  exit 0
fi

C_RESET=$'\033[0m'; DIM=$'\033[38;5;244m'
GREEN=$'\033[38;5;114m'; YELLOW=$'\033[38;5;179m'; RED=$'\033[38;5;203m'
BLUE=$'\033[38;5;110m'; MAGENTA=$'\033[38;5;176m'; CYAN=$'\033[38;5;80m'
MARK=$'\033[38;5;253m'

# Colour by threshold, or by how far ahead of pace we are when one is given.
pick_colour() {
  local pct=$1 pace=${2:--1}
  if (( pct >= 90 )); then printf '%s' "$RED"; return; fi
  if (( pace >= 0 )); then
    if (( pct > pace + 15 )); then printf '%s' "$RED"
    elif (( pct > pace )); then printf '%s' "$YELLOW"
    else printf '%s' "$GREEN"; fi
    return
  fi
  if (( pct >= 75 )); then printf '%s' "$RED"
  elif (( pct >= 50 )); then printf '%s' "$YELLOW"
  else printf '%s' "$GREEN"; fi
}

# 10-cell bar; pace >= 0 overlays the pace marker on its cell.
bar() {
  local pct=$1 pace=${2:--1} colour=$3 width=10 i filled pace_i out=""
  (( pct < 0 )) && pct=0; (( pct > 100 )) && pct=100
  filled=$(( (pct * width + 50) / 100 ))
  pace_i=-1
  if (( pace >= 0 )); then
    pace_i=$(( pace * width / 100 ))
    (( pace_i > width - 1 )) && pace_i=$(( width - 1 ))
  fi
  for (( i = 0; i < width; i++ )); do
    if (( i == pace_i )); then out+="${MARK}│${colour}"
    elif (( i < filled )); then out+="▓"
    else out+="${DIM}░${colour}"; fi
  done
  printf '%s%s%s' "$colour" "$out" "$C_RESET"
}

# Seconds -> 45m / 2h14m / 4d3h
countdown() {
  local s=$1
  (( s <= 0 )) && { printf 'now'; return; }
  if   (( s < 3600 ));  then printf '%dm' $(( s / 60 ))
  elif (( s < 86400 )); then printf '%dh%02dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
  else printf '%dd%dh' $(( s / 86400 )) $(( (s % 86400) / 3600 )); fi
}

# 15500 -> 15k, 1000000 -> 1M, 1200000 -> 1.2M
human() {
  local t=$1 whole frac
  if   (( t < 1000 ));    then printf '%d' "$t"
  elif (( t < 1000000 )); then printf '%dk' $(( t / 1000 ))
  else
    whole=$(( t / 1000000 )); frac=$(( (t % 1000000) / 100000 ))
    if (( frac == 0 )); then printf '%dM' "$whole"
    else printf '%d.%dM' "$whole" "$frac"; fi
  fi
}

NOW=$(date +%s)

# --- line 1 : identity -------------------------------------------------------
L1="${BLUE}${MODEL}${C_RESET}"
[[ $EFFORT != "-" ]] && L1+=" ${DIM}${EFFORT}${C_RESET}"
[[ $FAST == "1" ]] && L1+=" ${YELLOW}⚡${C_RESET}"
[[ $AGENT != "-" ]] && L1+=" ${MAGENTA}@${AGENT}${C_RESET}"

if [[ $WORKTREE != "-" ]]; then
  L1+=" ${DIM}·${C_RESET} ${MAGENTA}${REPO}${DIM}/${C_RESET}${MAGENTA}${WORKTREE}${C_RESET}"
elif [[ $REPO != "-" ]]; then
  L1+=" ${DIM}·${C_RESET} ${MAGENTA}${REPO}${C_RESET}"
else
  L1+=" ${DIM}·${C_RESET} ${MAGENTA}${CUR_DIR##*/}${C_RESET}"
fi

# git branch is the one shell-out; cache briefly, monorepos are slow
BRANCH=""
if [[ -d $CUR_DIR ]]; then
  CACHE="${TMPDIR:-/tmp}/cc-branch-$(printf '%s' "$CUR_DIR" | cksum | cut -d' ' -f1)"
  if [[ -f $CACHE ]] && (( NOW - $(stat -f %m "$CACHE" 2>/dev/null || echo 0) < 5 )); then
    BRANCH=$(<"$CACHE")
  else
    BRANCH=$(git --no-optional-locks -C "$CUR_DIR" symbolic-ref --short -q HEAD 2>/dev/null)
    printf '%s' "$BRANCH" >"$CACHE" 2>/dev/null
  fi
fi
[[ -n $BRANCH ]] && L1+=" ${CYAN} ${BRANCH}${C_RESET}"

if (( PR_NUM > 0 )); then
  case $PR_STATE in
    approved)         PR_C=$GREEN;  PR_G="✓" ;;
    changes_requested) PR_C=$RED;   PR_G="✗" ;;
    draft)            PR_C=$DIM;    PR_G="◌" ;;
    *)                PR_C=$YELLOW; PR_G="•" ;;
  esac
  L1+=" ${PR_C}#${PR_NUM}${PR_G}${C_RESET}"
fi

if (( ADDED > 0 || REMOVED > 0 )); then
  L1+=" ${DIM}·${C_RESET} ${GREEN}+${ADDED}${C_RESET}${DIM}/${C_RESET}${RED}-${REMOVED}${C_RESET}"
fi

# --- line 2 : budgets --------------------------------------------------------
CTX_TOTAL=$(( CTX_IN + CTX_OUT ))
CTX_C=$(pick_colour "$CTX_PCT")
L2="${DIM}ctx${C_RESET} $(bar "$CTX_PCT" -1 "$CTX_C") ${CTX_C}${CTX_PCT}%${C_RESET}"
L2+=" ${DIM}$(human "$CTX_TOTAL")/$(human "$CTX_SIZE")${C_RESET}"

if (( FIVE_PCT >= 0 )); then
  PACE=-1
  if (( FIVE_RESET > 0 )); then
    ELAPSED=$(( 18000 - (FIVE_RESET - NOW) ))
    (( ELAPSED < 0 )) && ELAPSED=0
    PACE=$(( ELAPSED * 100 / 18000 ))
    (( PACE > 100 )) && PACE=100
  fi
  C=$(pick_colour "$FIVE_PCT" "$PACE")
  L2+="  ${DIM}5h${C_RESET} $(bar "$FIVE_PCT" "$PACE" "$C") ${C}${FIVE_PCT}%${C_RESET}"
  (( FIVE_RESET > 0 )) && L2+=" ${DIM}↺$(countdown $(( FIVE_RESET - NOW )))${C_RESET}"
fi

if (( WK_PCT >= 0 )); then
  PACE=-1
  if (( WK_RESET > 0 )); then
    ELAPSED=$(( 604800 - (WK_RESET - NOW) ))
    (( ELAPSED < 0 )) && ELAPSED=0
    PACE=$(( ELAPSED * 100 / 604800 ))
    (( PACE > 100 )) && PACE=100
  fi
  C=$(pick_colour "$WK_PCT" "$PACE")
  L2+="  ${DIM}wk${C_RESET} $(bar "$WK_PCT" "$PACE" "$C") ${C}${WK_PCT}%${C_RESET}"
  (( WK_RESET > 0 )) && L2+=" ${DIM}↺$(countdown $(( WK_RESET - NOW )))${C_RESET}"
fi

L2+="  ${DIM}\$$(printf '%.2f' "$COST")${C_RESET}"

printf '%s\n%s\n' "$L1" "$L2"