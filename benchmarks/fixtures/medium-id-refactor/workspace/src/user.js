'use strict';

function normalizeId(value) {
  if (typeof value !== 'string') throw new TypeError('id must be a string');
  const normalized = value.trim().toUpperCase();
  if (!normalized || normalized.length > 32 || !/^[A-Z0-9_-]+$/.test(normalized)) {
    throw new TypeError('invalid id');
  }
  return normalized;
}

function createUser(id, name) {
  return { id: normalizeId(id), name };
}

module.exports = { createUser };
