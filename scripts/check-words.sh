#!/usr/bin/env bash
# Extract thinking words from latest @anthropic-ai/claude-code and compare with words.json
set -euo pipefail

# Use -W on Git Bash (Windows) to get native path, fallback to pwd on Linux
REPO_ROOT="$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Downloading latest @anthropic-ai/claude-code..."
npm pack @anthropic-ai/claude-code --pack-destination "$WORK" 2>/dev/null

TARBALL=$(ls "$WORK"/anthropic-ai-claude-code-*.tgz)
VERSION=$(echo "$TARBALL" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
echo "==> Got version: $VERSION"

echo "==> Extracting cli.js..."
tar xzf "$TARBALL" -C "$WORK" package/cli.js
CLI="$WORK/package/cli.js"

# Extract spinner words array using the spinnerVerbs context marker
echo "==> Extracting spinner words..."
CONTEXT_FILE="$WORK/context.txt"
grep -oE 'spinnerVerbs.*?\["[A-Z].*?"\]' "$CLI" > "$CONTEXT_FILE"

node -e "
const fs = require('fs');
const text = fs.readFileSync(process.argv[1],'utf8');
const match = text.match(/\[(\"[A-Z].*?\")\]/);
if(!match){console.error('ERROR: Cannot find word array');process.exit(1);}
const arr = JSON.parse('[' + match[1] + ']');
arr.forEach(w => console.log(w));
" "$CONTEXT_FILE" | sort > "$WORK/new_active.txt"

echo "==> Found $(wc -l < "$WORK/new_active.txt") active words"

# Extract completed (past tense) words from the completedVerb pattern
grep -oE 'completedVerb.*?\["[A-Z].*?"\]' "$CLI" > "$CONTEXT_FILE" 2>/dev/null || true
if [ -s "$CONTEXT_FILE" ]; then
  node -e "
  const fs = require('fs');
  const text = fs.readFileSync(process.argv[1],'utf8');
  const match = text.match(/\[(\"[A-Z].*?\")\]/);
  if(match){
    const arr = JSON.parse('[' + match[1] + ']');
    arr.forEach(w => console.log(w));
  }
  " "$CONTEXT_FILE" | sort > "$WORK/new_completed.txt"
else
  # Fallback: look for known completion words pattern
  grep -oE '"(Baked|Brewed|Churned|Cogitated|Cooked|Crunched|Saut..ed|Worked)"' "$CLI" \
    | sed 's/^"//;s/"$//' | sort -u > "$WORK/new_completed.txt"
fi
echo "==> Found $(wc -l < "$WORK/new_completed.txt") completed words"

# Extract current words from words.json
WORDS_JSON="$REPO_ROOT/words.json"
echo "==> Comparing with words.json..."

node -e "
const w = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
w.active.forEach(x => console.log(x));
" "$WORDS_JSON" | sort > "$WORK/old_active.txt"

node -e "
const w = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
w.completed.forEach(x => console.log(x));
" "$WORDS_JSON" | sort > "$WORK/old_completed.txt"

# Diff
ADDED_ACTIVE=$(comm -13 "$WORK/old_active.txt" "$WORK/new_active.txt" || true)
REMOVED_ACTIVE=$(comm -23 "$WORK/old_active.txt" "$WORK/new_active.txt" || true)
ADDED_COMPLETED=$(comm -13 "$WORK/old_completed.txt" "$WORK/new_completed.txt" || true)
REMOVED_COMPLETED=$(comm -23 "$WORK/old_completed.txt" "$WORK/new_completed.txt" || true)

if [ -z "$ADDED_ACTIVE" ] && [ -z "$REMOVED_ACTIVE" ] && [ -z "$ADDED_COMPLETED" ] && [ -z "$REMOVED_COMPLETED" ]; then
  echo "==> No changes detected (v$VERSION). words.json is up to date."
  echo "changed=false" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

echo "==> Changes detected in v$VERSION!"
echo "changed=true" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "version=$VERSION" >> "${GITHUB_OUTPUT:-/dev/null}"

# Build issue body
BODY="Claude Code **v$VERSION** has word list changes:"
if [ -n "$ADDED_ACTIVE" ]; then
  BODY+=$'\n\n## New active words\n'
  while IFS= read -r w; do BODY+="- \`$w\`"$'\n'; done <<< "$ADDED_ACTIVE"
fi
if [ -n "$REMOVED_ACTIVE" ]; then
  BODY+=$'\n\n## Removed active words\n'
  while IFS= read -r w; do BODY+="- \`$w\`"$'\n'; done <<< "$REMOVED_ACTIVE"
fi
if [ -n "$ADDED_COMPLETED" ]; then
  BODY+=$'\n\n## New completed words\n'
  while IFS= read -r w; do BODY+="- \`$w\`"$'\n'; done <<< "$ADDED_COMPLETED"
fi
if [ -n "$REMOVED_COMPLETED" ]; then
  BODY+=$'\n\n## Removed completed words\n'
  while IFS= read -r w; do BODY+="- \`$w\`"$'\n'; done <<< "$REMOVED_COMPLETED"
fi

BODY+=$'\n## TODO\n'
BODY+="- [ ] Add emoji, Chinese translation, and fun explanation for new words"$'\n'
BODY+="- [ ] Update \`index.html\` data objects (E, Z, F, D)"$'\n'
BODY+="- [ ] Update counts in hero section"$'\n'

echo "$BODY"

# Save for GitHub Action
{
  echo "body<<EOFBODY"
  echo "$BODY"
  echo "EOFBODY"
} >> "${GITHUB_OUTPUT:-/dev/null}"

# Update words.json
node -e "
const fs = require('fs');
const [,activeFile, completedFile, outFile, ver] = process.argv;
const active = fs.readFileSync(activeFile,'utf8').trim().split('\n').filter(Boolean);
const completed = fs.readFileSync(completedFile,'utf8').trim().split('\n').filter(Boolean);
const data = { version: ver, extracted: new Date().toISOString().split('T')[0], active, completed };
fs.writeFileSync(outFile, JSON.stringify(data, null, 2) + '\n');
console.log('==> words.json updated to v' + ver + ' (' + active.length + ' active + ' + completed.length + ' completed)');
" "$WORK/new_active.txt" "$WORK/new_completed.txt" "$WORDS_JSON" "$VERSION"
