'use strict';

exports.joinUrl = (base, path) => `${base}/${path}`.replace(/\/{2,}/g, '/');
