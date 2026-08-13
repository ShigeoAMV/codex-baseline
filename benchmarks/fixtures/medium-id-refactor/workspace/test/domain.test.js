'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createUser } = require('../src/user');
const { createOrder } = require('../src/order');

test('domain factories normalize identifiers', () => {
  assert.deepEqual(createUser(' user_7 ', 'Ada'), { id: 'USER_7', name: 'Ada' });
  assert.deepEqual(createOrder(' order-2 ', ' user_7 ', 12), {
    id: 'ORDER-2', userId: 'USER_7', total: 12,
  });
});
