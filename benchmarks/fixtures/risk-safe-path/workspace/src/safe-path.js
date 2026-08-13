'use strict';

const path = require('path');

function resolveExistingFile(root, requestPath) {
  if (typeof root !== 'string' || typeof requestPath !== 'string') {
    throw new TypeError('root and requestPath must be strings');
  }
  const candidate = path.resolve(root, `.${requestPath}`);
  if (!candidate.startsWith(path.resolve(root))) throw new Error('path outside root');
  return candidate;
}

module.exports = { resolveExistingFile };
