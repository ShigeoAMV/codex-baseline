'use strict';

exports.dedupeStable = (values, keyOf) => {
  return [...new Set(values.map((value) => ({key: keyOf(value), value})))]
    .map((entry) => entry.value);
};
