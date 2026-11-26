#!/usr/bin/env bash
# Usage: checks.sh BASE OUTFILE
# Lists the problems that the pull request adds, one per line: "path:line: [check] message".
# These are results of fixed checks, not guesses. Run it in the repository root, at
# the pull request head. MINT is the Mintlify CLI (default: mint).
set -uo pipefail
base=$1
out=$2
mint=${MINT:-mint}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
: > "$out"
export LC_ALL=C

added_diff() { git -c core.quotePath=false diff -U0 --no-color "$base" HEAD -- "$@"; }

# 1. Invisible characters and long dashes in the lines that this pull request adds.
added_diff '*.mdx' '*.md' '*.json' '*.yml' '*.yaml' '*.js' '*.py' | perl -ne '
  BEGIN { %name = ("\xEF\xBB\xBF" => "U+FEFF (byte order mark)", "\xE2\x80\x8B" => "U+200B (zero width space)",
    "\xE2\x80\x8C" => "U+200C (zero width non-joiner)", "\xE2\x80\x8D" => "U+200D (zero width joiner)",
    "\xE2\x80\x8E" => "U+200E (left-to-right mark)", "\xE2\x80\x8F" => "U+200F (right-to-left mark)",
    "\xE2\x81\xA0" => "U+2060 (word joiner)", "\xC2\xAD" => "U+00AD (soft hyphen)") }
  if (/^\+\+\+ b\/(.*)$/) { $f = $1; next }
  if (/^\+\+\+ /) { undef $f; next }
  if (/^@@ -\S+ \+(\d+)/) { $n = $1; next }
  next unless defined $f && /^\+/;
  my $l = substr($_, 1);
  my %seen;
  while ($l =~ /(\xEF\xBB\xBF|\xE2\x80[\x8B-\x8F]|\xE2\x81\xA0|\xC2\xAD)/g) {
    print "$f:$n: [hidden-character] The line has the invisible character $name{$1}. Remove it.\n" unless $seen{$1}++;
  }
  if ($f =~ /\.mdx?$/ && $l =~ /\xE2\x80[\x93\x94]/) {
    print "$f:$n: [long-dash] The line has a long dash (U+2014 or U+2013). Use a comma, a period or \" - \".\n";
  }
  $n++;
' >> "$out"

# 2. Image paths in added lines must match a file exactly, capital letters too.
#    The live site runs on Linux, where /images/Notion and /images/notion are different folders.
git ls-files > "$tmp/files"
added_diff '*.mdx' '*.md' | perl -ne '
  if (/^\+\+\+ b\/(.*)$/) { $f = $1; next }
  if (/^\+\+\+ /) { undef $f; next }
  if (/^@@ -\S+ \+(\d+)/) { $n = $1; next }
  next unless defined $f && /^\+/;
  while (/(?:\]\(|src=["\x27])(\/[^)"\x27\s]+\.(?:png|jpe?g|gif|svg|webp))/gi) {
    my $p = substr($1, 1); $p =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge; print "$f\t$n\t$p\n";
  }
  $n++;
' | sort -u | while IFS=$'\t' read -r f n p; do
  grep -qxF -- "$p" "$tmp/files" && continue
  alt=$(grep -ixF -- "$p" "$tmp/files" | head -n1)
  if [ -n "$alt" ]; then
    echo "$f:$n: [image-path] /$p does not exist. The file is /$alt. The capital letters are different, so the image does not load on the live site." >> "$out"
  else
    echo "$f:$n: [image-path] /$p does not exist in the repository." >> "$out"
  fi
done

# 3. Mintlify checks. Run them on the base and on the head, and keep only the new problems.
mkdir -p "$tmp/base" "$tmp/head"
git archive "$base" | tar -x -C "$tmp/base"
git archive HEAD | tar -x -C "$tmp/head"

links() {
  (cd "$1" && "$mint" broken-links --check-anchors --check-snippets --check-redirects 2>&1) \
    | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' \
    | awk '/^[^ ].*\.(mdx|md|json)$/ {f=$0; next}
           /^ +\xe2\x8e\xbf/ {sub(/^ +\xe2\x8e\xbf +/, ""); if ($0 != "@mintlify/components") print f "\t" $0}' \
    | sort -u
}
validate() {
  (cd "$1" && "$mint" validate --no-build --format json 2>/dev/null) \
    | jq -r '.diagnostics[]? | [(.file // "docs.json"), (.line // 1 | tostring), .rule, .severity, (.message | gsub("[\t\n]"; " "))] | @tsv' \
    | sort -u
}

if command -v "$mint" > /dev/null; then
  links "$tmp/base" > "$tmp/links.base"
  links "$tmp/head" > "$tmp/links.head"
  comm -13 "$tmp/links.base" "$tmp/links.head" | while IFS=$'\t' read -r f link; do
    n=$(grep -nF -- "$link" "$f" 2>/dev/null | head -n1 | cut -d: -f1)
    echo "$f:${n:-1}: [broken-link] $link does not point to a page, an anchor or a file that exists (mint broken-links)." >> "$out"
  done

  validate "$tmp/base" | awk -F'\t' '{print $1 "\t" $3 "\t" $5}' | sort -u > "$tmp/val.base"
  validate "$tmp/head" | while IFS=$'\t' read -r f n rule sev msg; do
    grep -qxF -- "$(printf '%s\t%s\t%s' "$f" "$rule" "$msg")" "$tmp/val.base" && continue
    echo "$f:$n: [mint-validate $rule, $sev] $msg" >> "$out"
  done
else
  echo "note: the Mintlify CLI is not installed, so broken links and MDX errors were not checked." >> "$out"
fi

# 4. New pages must be in the navigation. Deleted or renamed pages need a redirect.
git -c core.quotePath=false diff --name-status -M "$base" HEAD -- '*.mdx' | while IFS=$'\t' read -r st a b; do
  case "$st" in
    A) new=$a; old= ;;
    R*) new=$b; old=$a ;;
    D) new=; old=$a ;;
    *) continue ;;
  esac
  if [ -n "$new" ] && [ "${new#snippets/}" = "$new" ] \
     && [ "$(jq --arg p "${new%.mdx}" '[.navigation | .. | strings] | index($p) != null' docs.json)" = false ]; then
    echo "$new:1: [not-in-navigation] This new page is not in the docs.json navigation, so readers cannot find it in the sidebar." >> "$out"
  fi
  # Redirects are in docs.json, or in MOVED in scripts/build_redirects.py (see README.md).
  if [ -n "$old" ] && [ "${old#snippets/}" = "$old" ] \
     && [ "$(jq --arg s "/${old%.mdx}" '[.redirects[]?.source] | index($s) != null' docs.json)" = false ] \
     && ! grep -qF "\"${old%.mdx}\":" scripts/build_redirects.py 2> /dev/null; then
    echo "$old:1: [removed-page] This page was deleted or renamed, and no redirect from /${old%.mdx} exists. Links to the old address break." >> "$out"
  fi
done

sort -u -o "$out" "$out"
