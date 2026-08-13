'use strict';

const inFlight = new Map();

function getOrLoad(key, loader) {
  if (typeof loader !== 'function') throw new TypeError('loader must be a function');
  if (inFlight.has(key)) return Promise.resolve().then(loader);

  const pending = Promise.resolve().then(loader);
  inFlight.set(key, pending);
  return pending.finally(() => {
    inFlight.delete(key);
  });
}

module.exports = { getOrLoad };
