#!/usr/bin/env bash
# Collects the data for one review run into $OUT. Claude reads only these files,
# so it needs no GitHub access of its own.
#
# Run it in the repository root, with the pull request head checked out.
# Env: REPO PR OWNER OUT, and GH_TOKEN in GitHub Actions.
# Optional: FULL=1 (review the whole pull request), BASE_SHA, APP_REPOS,
# APP_TOKEN, APP_DIR, COMMENT_ID (an "@claude review" comment),
# EVAL=1 (a local test: read the pull request, but no review state, and change nothing),
# DRY_RUN=1 (read everything, change nothing).
set -euo pipefail
# Git writes file names with accents as they are, not as quoted escapes. checks.sh gets this too.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.quotePath GIT_CONFIG_VALUE_0=false

here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
eval_mode=${EVAL:-0}
full=${FULL:-0}
changes=true
if [ "$eval_mode" = 1 ] || [ "${DRY_RUN:-}" = 1 ]; then changes=false; fi

out() { if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi; }

head=$(git rev-parse HEAD)
gh pr view "$PR" --repo "$REPO" --json number,title,body,author,baseRefName,labels,url > "$OUT/pr.json"
author=$(jq -r .author.login "$OUT/pr.json")
base_ref=$(jq -r .baseRefName "$OUT/pr.json")
base=${BASE_SHA:-$(git merge-base "origin/$base_ref" HEAD)}

git diff --no-color "$base" HEAD > "$OUT/full.diff"
git diff --name-only "$base" HEAD > "$OUT/files.txt"

# The lines that GitHub accepts a review comment on: the new side of each hunk.
awk '/^\+\+\+ b\//{f=substr($0,7); next} /^\+\+\+ /{f=""; next} /^@@/{split($3,a,","); s=substr(a[1],2); n=(a[2]==""?1:a[2]); if(n>0 && f!="") print f": "s"-"(s+n-1)}' \
  "$OUT/full.diff" > "$OUT/lines.txt"

# The summary comment of the last run holds the last reviewed commit and the
# issues that had no line to attach to.
summary_id=""; last=""; reviews=0
echo '[]' > "$OUT/summary_only.json"
echo '[]' > "$OUT/threads.json"
if [ "$eval_mode" != 1 ]; then
  gh api "repos/$REPO/issues/$PR/comments" --paginate --slurp \
    | jq '[.[][] | select(.user.login == "github-actions[bot]" and (.body | startswith("<!-- claude-review")))] | first // {}' \
    > "$OUT/summary.json"
  summary_id=$(jq -r '.id // empty' "$OUT/summary.json")
  marker=$(jq -r '.body // "" | split("\n")[0]' "$OUT/summary.json")
  last=$(sed -n 's/.*reviewed:\([0-9a-f]\{40\}\).*/\1/p' <<<"$marker")
  reviews=$(sed -n 's/.*reviews:\([0-9]*\).*/\1/p' <<<"$marker")
  reviews=${reviews:-0}
  state=$(jq -r '.body // ""' "$OUT/summary.json" | sed -n 's/^<!-- claude-review-state \([A-Za-z0-9+/=]*\) -->$/\1/p')
  if [ -n "$state" ]; then base64 -d <<<"$state" > "$OUT/summary_only.json" 2>/dev/null || echo '[]' > "$OUT/summary_only.json"; fi

  "$here/threads.sh" > "$OUT/threads.json"
fi

# Replies from the author or the owner that wait for an answer.
jq --arg author "$author" --arg owner "$OWNER" '
  [.[] | select((.comments | last | .bot | not) and ((.comments | last | .author) as $a | $a == $author or $a == $owner))
   | {thread_id, root_id, path, line, resolved, from: (.comments | last | .author), reply: (.comments | last | .body)}]
' "$OUT/threads.json" > "$OUT/replies.json"

# What to review: the commits after the last reviewed one, or the whole pull request.
if [ "$full" = 1 ] || [ -z "$last" ] || ! git cat-file -e "$last^{commit}" 2>/dev/null || ! git merge-base --is-ancestor "$last" HEAD; then
  mode=full
  cp "$OUT/full.diff" "$OUT/new.diff"
  range="$base"
else
  # Only the files of this pull request, so commits that came in from main do not count.
  : > "$OUT/new.diff"
  if [ -s "$OUT/files.txt" ]; then tr '\n' '\0' < "$OUT/files.txt" | xargs -0 git diff --no-color "$last" HEAD -- > "$OUT/new.diff"; fi
  range="$last"
  if [ -s "$OUT/new.diff" ]; then mode=incremental; else mode=replies; fi
fi

if [ "$mode" = replies ] && [ "$(jq length "$OUT/replies.json")" = 0 ]; then
  echo "Nothing to do: no new commits and no replies that wait for an answer."
  out skip true
  exit 0
fi

if [ -n "${COMMENT_ID:-}" ] && [ "$changes" = true ]; then
  gh api "repos/$REPO/issues/comments/$COMMENT_ID/reactions" -f content=eyes > /dev/null || true
fi

# New commits remove the ready-to-merge label until this run says the pull request is ready again.
had_label=$(jq '[.labels[].name] | index("ready-to-merge") != null' "$OUT/pr.json")
if [ "$mode" != replies ] && [ "$had_label" = true ] && [ "$changes" = true ]; then
  gh api -X DELETE "repos/$REPO/issues/$PR/labels/ready-to-merge" > /dev/null || true
fi

# Rules that the author or the owner approved. They live on their own branch, so a learned rule
# does not need a commit to main.
if [ -n "${RULES_FILE:-}" ]; then
  cp "$RULES_FILE" "$OUT/rules.md"
elif ! git show origin/claude-review-rules:rules.md > "$OUT/rules.md" 2>/dev/null; then
  echo "No rules yet." > "$OUT/rules.md"
fi

# A code review runs when the new commits change code: scripts, config, the review
# itself, or code examples in pages. Only the files of this pull request count.
code=false
if [ "$mode" != replies ]; then
  changed=$(git diff --name-only "$range" HEAD | grep -xFf "$OUT/files.txt" || true)
  pages=$(grep -E '\.mdx?$' <<<"$changed" || true)
  if grep -E '^\.github/' <<<"$changed" > /dev/null \
     || grep -vE '\.(mdx|md|png|jpe?g|gif|svg|webp|ico)$|^docs\.json$|^$' <<<"$changed" > /dev/null \
     || { [ -n "$pages" ] && tr '\n' '\0' <<<"$pages" | xargs -0 git diff "$range" HEAD -- \
          | grep -E '^\+.*(```|<CodeGroup|<RequestExample|<ResponseExample)' > /dev/null; }; then
    code=true
  fi
fi
echo "No code review ran on these commits." > "$OUT/code_review.md"

# The app code, to check what the pages say about the product. Read-only.
app_dirs='[]'
app_gh() { if [ -n "${APP_TOKEN:-}" ]; then GH_TOKEN=$APP_TOKEN gh "$@"; else gh "$@"; fi; }
if [ -n "${APP_REPOS:-}" ] && [ -n "${APP_DIR:-}" ] && { [ -n "${APP_TOKEN:-}" ] || [ "$eval_mode" = 1 ]; }; then
  mkdir -p "$APP_DIR"
  for r in $APP_REPOS; do
    d="$APP_DIR/${r#*/}"
    if [ ! -d "$d" ]; then app_gh repo clone "$r" "$d" -- --depth 1 --quiet || { echo "::warning::Could not read $r"; continue; }; fi
    app_dirs=$(jq --arg d "$d" '. + [$d]' <<<"$app_dirs")
  done

  # Code pull requests that the description links to (for example owner/app#12).
  jq -r '.body // ""' "$OUT/pr.json" \
    | { grep -oE '(github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+)' || true; } \
    | sed -E 's#github\.com/##; s#/pull/#\##' | sort -u | while read -r ref; do
      r=${ref%#*}; n=${ref#*#}
      case " $APP_REPOS " in *" $r "*) ;; *) continue ;; esac
      f="$OUT/companion-${r#*/}-$n.diff"
      { app_gh pr view "$n" --repo "$r" --json title,body,state,mergedAt --jq '"# \(.title) (\(.state))\n\n\(.body)\n"'
        { app_gh pr diff "$n" --repo "$r" || true; } | head -c 400000; } > "$f" 2>/dev/null || rm -f "$f"
    done
fi

"$here/checks.sh" "$base" "$OUT/checks.txt"

jq -n \
  --arg repo "$REPO" --argjson pr "$PR" --arg url "$(jq -r .url "$OUT/pr.json")" \
  --arg author "$author" --arg owner "$OWNER" --arg head "$head" --arg base "$base" \
  --arg mode "$mode" --arg last "$last" --argjson reviews "$reviews" \
  --arg summary_id "$summary_id" --argjson had_label "$had_label" --argjson code "$code" \
  --argjson app_dirs "$app_dirs" \
  --arg companion "$(cd "$OUT" && ls companion-*.diff 2>/dev/null | tr '\n' ' ')" \
  '{repo: $repo, pr: $pr, url: $url, author: $author, owner: $owner, head: $head, base: $base,
    mode: $mode, last_reviewed: $last, reviews: $reviews, summary_id: $summary_id,
    had_label: $had_label, code_review: $code, app_dirs: $app_dirs,
    companion_prs: ($companion | split(" ") | map(select(. != "")))}' > "$OUT/context.json"

out skip false
out mode "$mode"
out code "$code"
out base "$base"
out head "$head"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  d="EOF_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  { echo "prompt<<$d"; sed "s#{{PACKET}}#$OUT#g" "$here/prompt.md"; echo "$d"; } >> "$GITHUB_OUTPUT"
  echo "schema=$(jq -c . "$here/schema.json")" >> "$GITHUB_OUTPUT"
  echo "add_dirs=$(jq -r '[$out] + .app_dirs | map("--add-dir " + @sh) | join(" ")' --arg out "$OUT" "$OUT/context.json")" >> "$GITHUB_OUTPUT"
fi
echo "Mode: $mode. Code review: $code. Checks: $(grep -c . "$OUT/checks.txt" || true) findings."
