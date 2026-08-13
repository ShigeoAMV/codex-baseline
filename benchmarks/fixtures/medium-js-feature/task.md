Implement `quote(lines, discountPercent)` in `src/quote.js`. It must validate
that `lines` is a non-empty array of `{quantity, unitPrice}` with positive
integer quantity and finite non-negative unit price; validate discount as a
finite number from 0 through 100; return an immutable `{subtotal, discount,
total}` rounded to two decimal places. Reuse `roundMoney` from `src/money.js`.
Do not add dependencies or alter exported APIs outside `src/quote.js`.
