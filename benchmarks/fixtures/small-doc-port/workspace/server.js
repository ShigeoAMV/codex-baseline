'use strict';

function portFrom(env) {
  const raw = env.PORT;
  if (raw === undefined) return 3000;
  const port = Number(raw);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new TypeError('PORT must be an integer from 1 through 65535');
  }
  return port;
}

module.exports = { portFrom };
