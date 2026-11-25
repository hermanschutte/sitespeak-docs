#!/usr/bin/env bash
# Prints the review threads that github-actions started on pull request $PR in $REPO, with all comments.
# GraphQL gives the bot's login as "github-actions", REST as "github-actions[bot]".
set -euo pipefail

gh api graphql --paginate --slurp -F owner="${REPO%/*}" -F name="${REPO#*/}" -F pr="$PR" -f query='
  query($owner: String!, $name: String!, $pr: Int!, $endCursor: String) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id isResolved isOutdated path line startLine
            comments(first: 100) { nodes { databaseId url author { login } body createdAt } }
          }
        }
      }
    }
  }' | jq '
  def bot: . == "github-actions" or . == "github-actions[bot]";
  [.[].data.repository.pullRequest.reviewThreads.nodes[]
   | select(.comments.nodes[0].author.login // "" | bot)
   | {thread_id: .id, resolved: .isResolved, outdated: .isOutdated, path, line, start_line: .startLine,
      root_id: .comments.nodes[0].databaseId, url: .comments.nodes[0].url,
      comments: [.comments.nodes[] | {author: (.author.login // "ghost"), bot: (.author.login // "" | bot), body, created_at: .createdAt}]}]'
