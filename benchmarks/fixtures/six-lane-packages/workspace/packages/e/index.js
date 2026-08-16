'use strict';

exports.partitionSettled = (results) => {
  const fulfilled = [];
  const rejected = [];
  for (const result of results) {
    if (result.status === 'fulfilled' && result.value) fulfilled.push(result.value);
    if (result.status === 'rejected' && result.reason) rejected.push(result.reason);
  }
  return {fulfilled, rejected};
};
