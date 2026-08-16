import fs from 'node:fs';

const [diffPath, lastMessagePath] = process.argv.slice(2);
if (!diffPath || !lastMessagePath) throw new Error('usage: node hygiene.mjs DIFF LAST_MESSAGE');

const diff = fs.readFileSync(diffPath, 'utf8').split(/\r?\n/);
const lastMessageBytes = fs.readFileSync(lastMessagePath).length;
const codeSuffix = /\.(?:[cm]?[jt]sx?|py|rb|go|rs|java|kt|kts|c|cc|cpp|h|hpp|cs|php|sh|bash|zsh|fish|ps1|psm1|sql|css|scss|less|html|vue|svelte|json|ya?ml|toml|xml)$/i;
const proseSuffix = /\.(?:md|mdx|rst|txt|adoc)$/i;
const commentStart = /^(?:\/\/|\/\*|\*|\*\/|#(?!\!)|<!--|--)/;
let currentPath = '';
let inHeaders = false;
let sawOldPath = false;
let addedLines = 0;
let addedCodeLines = 0;
let addedCommentLines = 0;
let addedProseLines = 0;
let addedBlankLines = 0;
let duplicateAddedLines = 0;
let removedNoncommentLines = 0;
const seenByPath = new Map();

for (const line of diff) {
  if (line.startsWith('diff --git ')) {
    inHeaders = true;
    sawOldPath = false;
    continue;
  }
  if (inHeaders && line.startsWith('--- ')) {
    sawOldPath = true;
    continue;
  }
  if (inHeaders && sawOldPath && line.startsWith('+++ ')) {
    const rawPath = line.slice(4);
    try { currentPath = rawPath.startsWith('"') ? JSON.parse(rawPath) : rawPath; }
    catch { currentPath = rawPath; }
    currentPath = currentPath.replace(/^b\//, '');
    continue;
  }
  if (line.startsWith('@@')) {
    inHeaders = false;
    continue;
  }
  if (inHeaders) continue;
  if (line.startsWith('-')) {
    const content = line.slice(1).trim();
    if (content && !commentStart.test(content)) removedNoncommentLines++;
    continue;
  }
  if (!line.startsWith('+')) continue;
  addedLines++;
  const content = line.slice(1);
  const normalized = content.trim().replace(/\s+/g, ' ');
  if (!normalized) {
    addedBlankLines++;
    continue;
  }
  const seen = seenByPath.get(currentPath) ?? new Set();
  if (seen.has(normalized)) duplicateAddedLines++;
  seen.add(normalized);
  seenByPath.set(currentPath, seen);
  if (codeSuffix.test(currentPath) && commentStart.test(normalized)) addedCommentLines++;
  else if (proseSuffix.test(currentPath)) addedProseLines++;
  else addedCodeLines++;
}

const pureCommentDiff = addedCommentLines > 0 && addedCodeLines === 0 && addedProseLines === 0 &&
  removedNoncommentLines === 0;
process.stdout.write(`${JSON.stringify({
  last_message_bytes: lastMessageBytes,
  added_lines: addedLines,
  added_code_lines: addedCodeLines,
  added_comment_lines: addedCommentLines,
  added_prose_lines: addedProseLines,
  added_blank_lines: addedBlankLines,
  duplicate_added_lines: duplicateAddedLines,
  pure_comment_diff: pureCommentDiff,
  hygiene_verification: 'verified',
  hygiene_provenance: 'host-git-diff-objective/v1'
})}\n`);
