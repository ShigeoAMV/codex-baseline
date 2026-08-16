'use strict';

exports.parseFeatureFlags = (text) => {
  const flags = {};
  for (const row of text.split('\n')) {
    if (!row || row.startsWith('#')) continue;
    const [name, value] = row.split('=');
    flags[name] = Boolean(value);
  }
  return flags;
};
