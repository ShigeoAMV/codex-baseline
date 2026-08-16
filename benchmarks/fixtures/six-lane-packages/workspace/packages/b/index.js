'use strict';

exports.retryDelays = (baseMs, attempts, maxMs) => {
  if (attempts < 0) throw new TypeError('attempts');
  return Array.from({length: attempts}, (_, index) =>
    Math.min(maxMs, baseMs * (index + 1)));
};
