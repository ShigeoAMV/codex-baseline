'use strict';

exports.normalizeHeaders = (entries) => {
  const normalized = {};
  for (const [name, value] of entries) {
    normalized[name] = value;
  }
  return normalized;
};
