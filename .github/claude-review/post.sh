#!/usr/bin/env bash
# Posts the result of a review run: the new comments, the replies, the resolved
# threads and the summary comment. Then sets the ready-to-merge label.
# Env: GH_TOKEN REPO PR OUT, and RESULT (the JSON that Claude returned).
# DRY_RUN=1 prints each change instead of making it.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
ctx() { jq -r "$1" "$OUT/context.json"; }

# write METHOD PATH < json
write() {
  if [ "${DRY_RUN:-}" = 1 ]; then
    { echo "--- $1 $2"; cat; echo; } >&2
  else
    gh api -X "$1" "$2" --input - > /dev/null
  fi
}

if ! jq -e 'type == "object" and (.reviewed | type) == "boolean"' <<<"${RESULT:-}" > /dev/null 2>&1; then
  echo "::error::The review step returned no result, so nothing was posted. Push a commit or comment \"@claude review\" to run it again."
  exit 1
fi

head=$(ctx .head); last=$(ctx .last_reviewed); mode=$(ctx .mode)
author=$(ctx .author); owner=$(ctx .owner); url=$(ctx .url)
reviews=$(ctx .reviews); summary_id=$(ctx .summary_id); had_label=$(ctx .had_label)
reviewed=$(jq -r .reviewed <<<"$RESULT")

# New rules and the threads to resolve go to separate jobs that may write to the repository
# (GitHub resolves a thread only for a token with contents: write). Write them first, so that a
# failed GitHub call below does not lose them. Only a finished review resolves threads or adds
# rules. Claude may resolve only its own threads. Only the owner can approve a rule: a rule counts
# only from a thread where the owner wrote the reply.
resolve='[]'; rules='[]'
if [ "$reviewed" = true ]; then
  resolve=$(jq -c --slurpfile th "$OUT/threads.json" '[.resolve[] | select(. as $t | $th[0] | map(.thread_id) | index($t))]' <<<"$RESULT")
  rules=$(jq -c --slurpfile rp "$OUT/replies.json" --arg owner "$owner" \
    '[.add_rules[] | select(.thread_id as $t | $rp[0] | any(.thread_id == $t and .from == $owner)) | .rule]' <<<"$RESULT")
  if [ "$(jq length <<<"$rules")" != "$(jq '.add_rules | length' <<<"$RESULT")" ]; then
    echo "::warning::A rule did not come from a reply of $owner, so it was not added."
  fi
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  [ "$rules" = '[]' ] || echo "rules=$rules" >> "$GITHUB_OUTPUT"
  [ "$resolve" = '[]' ] || echo "resolve=$resolve" >> "$GITHUB_OUTPUT"
fi

# 1. New comments. A comment that GitHub refuses (its line is not in the diff) goes to the summary.
failed='[]'; posted='[]'
while IFS= read -r c; do
  [ -n "$c" ] || continue
  body=$(jq -r '
    (if .security then " · **Security**" else "" end) as $sec
    | ((.suggestion // "") | if contains("```") then "````" else "```" end) as $fence
    | (if (.suggestion // "") == "" then "" else "\(.suggestion)\n" end) as $text
    | "**\(.severity)**\($sec) · **\(.title)**\n\n\(.body)"
      + (if has("suggestion") then "\n\n\($fence)suggestion\n\($text)\($fence)" else "" end)
      + "\n\n<sub>Reply here to change the suggestion, or to keep the text as it is.</sub>"' <<<"$c")
  payload=$(jq -c --arg head "$head" --arg body "$body" '
    {commit_id: $head, path, line, side: "RIGHT", body: $body}
    + (if (.start_line // 0) > 0 and .start_line < .line then {start_line, start_side: "RIGHT"} else {} end)' <<<"$c")
  if [ "${DRY_RUN:-}" = 1 ]; then
    write POST "repos/$REPO/pulls/$PR/comments" <<<"$payload"; resp='{"id": 0, "html_url": "#"}'
  elif ! resp=$(gh api -X POST "repos/$REPO/pulls/$PR/comments" --input - <<<"$payload"); then
    echo "::warning::GitHub refused a comment on $(jq -r '"\(.path) line \(.line)"' <<<"$c" | tr '\n\r' '  '). It goes in the summary."
    failed=$(jq -c --argjson c "$c" '. + [$c | {severity, security, title, path, body: "\(.body) (line \(.line))"}]' <<<"$failed")
    continue
  fi
  posted=$(jq -c --argjson c "$c" --argjson r "$resp" \
    '. + [{root_id: $r.id, severity: $c.severity, security: ($c.security // false), title: $c.title, url: $r.html_url}]' <<<"$posted")
done < <(jq -c '.comments[]' <<<"$RESULT")

# 2. Replies in threads, only from a finished review and only in the review's own threads.
while IFS= read -r r; do
  [ -n "$r" ] || continue
  write POST "repos/$REPO/pulls/$PR/comments/$(jq -r .root_id <<<"$r")/replies" <<<"$(jq -c '{body}' <<<"$r")" \
    || echo "::warning::Could not reply in thread $(jq -r .thread_id <<<"$r" | tr '\n\r' '  ')."
done < <([ "$reviewed" != true ] || jq -c --slurpfile th "$OUT/threads.json" '.replies[] | . as $r | first($th[0][] | select(.thread_id == $r.thread_id)) | {root_id, body: $r.body, thread_id}' <<<"$RESULT")
# A reply that Claude resolved without an answer stays the last comment, and each later run would answer it again.
while IFS= read -r root; do
  [ -n "$root" ] || continue
  write POST "repos/$REPO/pulls/$PR/comments/$root/replies" <<<'{"body": "Thanks. I resolved this thread."}' \
    || echo "::warning::Could not reply in the thread of comment $root."
done < <(jq -r --argjson r "$RESULT" --argjson res "$resolve" '.[] | select(.thread_id as $t | ($res | index($t)) and ([$r.replies[].thread_id] | index($t) | not)) | .root_id' "$OUT/replies.json")

# 3. The threads that are fixed or that the author keeps. The resolve-threads job resolves them.
if [ "${DRY_RUN:-}" = 1 ]; then jq -r '.[] | "--- resolve \(.)"' <<<"$resolve" >&2; fi

# 4. Count what is open now. The first line of each finding has its severity and title.
#    A comment from step 1 can be missing from the GraphQL answer for a moment, so it comes from $posted.
open_threads=$("$here/threads.sh" | jq -c --argjson res "$resolve" --argjson posted "$posted" '
  [.[] | select((.resolved | not) and (.thread_id as $t | $res | index($t) | not))
   | (.comments[0].body | split("\n")[0]) as $first
   | ($first | capture("^\\*\\*(?<severity>P[0-2])\\*\\*(?<sec> · \\*\\*Security\\*\\*)? · \\*\\*(?<title>.+)\\*\\*$")
      // {severity: "P2", sec: null, title: ($first | .[0:80])}) as $m
   | {root_id, severity: $m.severity, security: (($m.sec // "") != ""), title: $m.title, url}]
  | map(.root_id) as $seen
  | . + [$posted[] | select(.root_id as $id | $seen | index($id) | not)]
  | map(del(.root_id))')
if [ "$reviewed" = true ]; then
  so=$(jq -c --argjson failed "$failed" '.summary_only + $failed' <<<"$RESULT")
else
  # The review did not finish, so keep the issues of the last run.
  so=$(jq -c --argjson failed "$failed" '. + $failed' "$OUT/summary_only.json")
fi
# A failed code review keeps the pull request open. The last reviewed commit stays as it
# was (step 5), so the next run reviews the code again.
shown=$so
if [ -f "$OUT/code_review_failed" ]; then
  shown=$(jq -c '. + [{severity: "P2", security: false, title: "The code review did not finish", body: "Comment `@claude review` to run it again."}]' <<<"$so")
fi
open=$(( $(jq length <<<"$open_threads") + $(jq length <<<"$shown") ))

# 5. The summary comment. Its first line keeps the last reviewed commit for the next run.
if [ "$reviewed" = true ] && [ ! -f "$OUT/code_review_failed" ]; then
  mark=$head
  [ "$mode" = replies ] || reviews=$((reviews + 1))
else
  mark=$last
fi
subject=""
[ -n "$mark" ] && subject=$(git log -1 --format=%s "$mark" 2>/dev/null | tr -d '[]' || true)

body=$(jq -n -r --argjson r "$RESULT" --argjson threads "$open_threads" --argjson so "$shown" --argjson open "$open" \
  --arg mark "$mark" --argjson reviews "$reviews" --arg url "$url" --arg subject "$subject" \
  --arg state "$(jq -c . <<<"$so" | base64 | tr -d '\n')" '
  def badge: "**\(.severity)**" + (if .security then " · **Security**" else "" end);
  ($r.diagram | sub("^\\s*```(mermaid)?\\s*"; "") | sub("\\s*```\\s*$"; "")) as $diagram
  | [ "<!-- claude-review reviewed:\($mark) reviews:\($reviews) -->",
      "## Claude review",
      "",
      (if $r.reviewed and $open == 0 then "**Confidence: 5/5** · No open issues. Ready to merge."
       else "**Confidence: \([$r.confidence, 4] | min)/5** · **\($r.impact[0:1] | ascii_upcase)\($r.impact[1:]) impact**" end),
      "",
      $r.verdict,
      "",
      (if $r.reviewed | not then "> [!WARNING]\n> The review did not finish: \($r.error // "no reason given"). Push a commit or comment `@claude review` to run it again.\n" else empty end),
      (if $open > 0 then
        "### Open issues (\($open))\n\n"
        + ([($threads[] | "1. \(badge) [\(.title)](\(.url))"),
            ($so[] | "1. \(badge) **\(.title)**" + (if .path then " (`\(.path)`)" else "" end) + ": \(.body)")] | join("\n"))
        + "\n"
       else empty end),
      "### Summary",
      "",
      $r.overview,
      "",
      (if $diagram != "" then "<details><summary>Diagram</summary>\n\n```mermaid\n\($diagram)\n```\n\n</details>\n" else empty end),
      "<sub>Reviews (\($reviews)) · Last reviewed commit: "
        + (if $mark != "" then "[\($subject)](\($url)/commits/\($mark))" else "none" end)
        + " · Reply in a thread to discuss a finding. Comment `@claude review` for a full review.</sub>",
      "",
      "<!-- claude-review-state \($state) -->"
    ] | join("\n")')

if [ -n "$summary_id" ]; then
  write PATCH "repos/$REPO/issues/comments/$summary_id" <<<"$(jq -n --arg b "$body" '{body: $b}')"
else
  write POST "repos/$REPO/issues/$PR/comments" <<<"$(jq -n --arg b "$body" '{body: $b}')"
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$body" >> "$GITHUB_STEP_SUMMARY"; fi

# 6. The label, and a review request to the owner when the pull request becomes ready.
has_label=$(gh api "repos/$REPO/issues/$PR/labels" --jq 'map(.name) | index("ready-to-merge") != null')
if [ "$reviewed" = true ] && [ "$open" = 0 ]; then
  if [ "$has_label" = false ]; then
    write POST "repos/$REPO/issues/$PR/labels" <<<'{"labels": ["ready-to-merge"]}' \
      || echo "::warning::Could not add the ready-to-merge label."
    if [ "$author" != "$owner" ]; then
      write POST "repos/$REPO/pulls/$PR/requested_reviewers" <<<"$(jq -n --arg o "$owner" '{reviewers: [$o]}')" \
        || echo "::warning::Could not ask $owner for a review."
    fi
  fi
else
  if [ "$has_label" = true ]; then write DELETE "repos/$REPO/issues/$PR/labels/ready-to-merge" <<<'{}' || true; fi
  if [ "$had_label" = true ] && [ "$author" != "$owner" ]; then
    write DELETE "repos/$REPO/pulls/$PR/requested_reviewers" <<<"$(jq -n --arg o "$owner" '{reviewers: [$o]}')" || true
  fi
fi

echo "Open issues: $open."
if [ "$reviewed" != true ]; then
  echo "::error::The review did not finish: $(jq -r '.error // "no reason given"' <<<"$RESULT" | tr '\n\r' '  ')"
  exit 1
fi
