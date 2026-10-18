function y = fir_model(h, x)
%FIR_MODEL Fixed-point golden model of the FIR filter in sw/fir.c and
%rtl/peripherals/fir_filter.sv, written with Fixed-Point Designer.
%
%   y = fir_model(h, x) filters the samples x with the coefficients h, both
%   signed 16-bit Q15 values (given as integers), and returns the outputs as
%   int16. Samples before x(1) are zero. Each product is a full-precision
%   Q30 value and the sum is kept at full precision (37 bits for 16 taps),
%   then converted to Q15 with round-to-nearest, ties toward +infinity
%   (fimath 'Nearest', the same as (acc + 2^14) >> 15) and saturation.
%
%   The result is cross-checked against a plain integer computation in
%   doubles (exact here, since |acc| < 2^36), so a fimath setting that
%   differed from the hardware would stop the model with an error.
h = int64(h(:).');
x = int64(x(:));
taps = numel(h);
n = numel(x);
F = fimath('ProductMode', 'FullPrecision', 'SumMode', 'FullPrecision', ...
           'RoundingMethod', 'Floor', 'OverflowAction', 'Wrap');
hq = fi(double(h) / 2^15, 1, 16, 15, F);       % exact: the stored integers are h
% Row i holds x(i), x(i-1), ..., x(i-taps+1), zero before the first sample.
delayed = zeros(n, taps);
for k = 1:taps
    delayed(k:n, k) = double(x(1:n-k+1));
end
xq = fi(delayed / 2^15, 1, 16, 15, F);
acc = xq * hq.';                          % full-precision sum of products
out = fi(acc, 1, 16, 15, 'RoundingMethod', 'Nearest', 'OverflowAction', 'Saturate');
y = int16(out.storedInteger);

% Independent integer computation of the same thing.
acc_int = delayed * double(h).';          % exact: every term < 2^30, |sum| < 2^36
ref = floor((acc_int + 2^14) / 2^15);
ref = min(max(ref, -32768), 32767);
if ~isequal(double(y), ref)
    error('fir_model:mismatch', 'fi model and integer model differ');
end
if ~isequal(double(acc.storedInteger), acc_int)
    error('fir_model:accumulator', 'fi accumulator is not exact');
end
end
