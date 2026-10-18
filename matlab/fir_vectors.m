function fir_vectors(out_dir)
%FIR_VECTORS Expected outputs from fir_model for the FIR checks.
%
%   fir_vectors(out_dir) writes, under out_dir (default build/fir):
%     fir_cases.txt     test cases for tb/unit/fir_tb.sv: coefficients,
%                       inputs and the outputs fir_model gives for them
%     fir_soc.txt       the sw/fir.c data set and its expected outputs, for
%                       the SoC test of the hardware FIR (tb/core/soc_fir_hw_tb.sv)
%     lowpass.txt       Q15 coefficients of a 16-tap low-pass filter
%                       (fir1, cutoff at 0.2 of Nyquist) for the ADC-model bench
%     fir_vectors.log   what was generated, and the check below
%
%   It first checks fir_model against the Python reference used by the
%   firmware (scripts/fir_reference.py writes build/firmware/fir_expected.json):
%   the outputs for the sw/fir.c data set must be identical.
%
%   Case file format, all integers in decimal: the number of cases, then per
%   case a line "taps n", a line of taps coefficients, and n lines "x y".
here = fileparts(mfilename('fullpath'));
root = fileparts(here);
if nargin < 1, out_dir = fullfile(root, 'build', 'fir'); end
if ~exist(out_dir, 'dir'), mkdir(out_dir); end
log = fopen(fullfile(out_dir, 'fir_vectors.log'), 'w');
cleanup = onCleanup(@() fclose(log));
say = @(varargin) fprintf_both(log, varargin{:});
say('MATLAB %s, %s\n', version, toolboxes());

% ---------------------------------------------------- sw/fir.c data set
ref = jsondecode(fileread(fullfile(root, 'build', 'firmware', 'fir_expected.json')));
y = fir_model(ref.coefficients, ref.input);
if ~isequal(double(y), ref.outputs(:))
    error('fir_vectors:python', 'fir_model differs from scripts/fir_reference.py');
end
say('FIR_MODEL_MATCHES_PYTHON taps=%d samples=%d saturated=%d checksum=0x%016x\n', ...
    numel(ref.coefficients), numel(ref.input), sum(y == 32767 | y == -32768), ...
    checksum(y));
write_cases(fullfile(out_dir, 'fir_soc.txt'), {{ref.coefficients, ref.input}});

% ------------------------------------------------------- unit-test cases
rng(2026, 'twister');
cases = {};
cases{end+1} = {ref.coefficients, ref.input};                       % the firmware data set
for c = 1:4                                                          % random, full range
    cases{end+1} = {randi([-32768 32767], 16, 1), randi([-32768 32767], 256, 1)};
end
cases{end+1} = {repmat([32767; -32768], 8, 1), repmat([-32768; 32767], 64, 1)};   % saturates both ways
cases{end+1} = {32767 * ones(16, 1), 32767 * ones(64, 1)};          % largest positive sum
cases{end+1} = {-32768 * ones(16, 1), 32767 * ones(64, 1)};         % largest negative sum
cases{end+1} = {-32768 * ones(16, 1), -32768 * ones(64, 1)};        % -1 * -1, every tap
ties = [16384; zeros(15, 1)];                                        % acc = +-2^14 * x: exact half-LSB ties
cases{end+1} = {ties, [1; -1; 3; -3; 5; -5; 0; 2; -2; 32767; -32768; 7; -7; 1; -1; 0]};
cases{end+1} = {[zeros(15, 1); 1], randi([-32768 32767], 64, 1)};   % only the oldest tap
cases{end+1} = {[1; zeros(15, 1)], randi([-32768 32767], 64, 1)};   % only the newest tap
lp = lowpass_q15();
t = (0:255).';
cases{end+1} = {lp, round(12000 * sin(2*pi*0.03*t) + 8000 * sin(2*pi*0.4*t))};   % the ADC bench filter
write_cases(fullfile(out_dir, 'fir_cases.txt'), cases);
total = sum(cellfun(@(c) numel(c{2}), cases));
say('FIR_CASES cases=%d outputs=%d\n', numel(cases), total);

fid = fopen(fullfile(out_dir, 'lowpass.txt'), 'w');
fprintf(fid, '%d\n', lp);
fclose(fid);
say('LOWPASS_Q15 %s\n', sprintf('%d ', lp));
end

function write_cases(path, cases)
fid = fopen(path, 'w');
fprintf(fid, '%d\n', numel(cases));
for c = 1:numel(cases)
    h = cases{c}{1}; x = cases{c}{2};
    y = fir_model(h, x);
    fprintf(fid, '%d %d\n', numel(h), numel(x));
    fprintf(fid, '%s\n', strtrim(sprintf('%d ', h)));
    fprintf(fid, '%d %d\n', [double(x(:)) double(y(:))].');
end
fclose(fid);
end

function lp = lowpass_q15()
% 16-tap Hamming-window low-pass, cutoff at 0.2 of the Nyquist frequency
% (0.1 of the sample rate), rounded to Q15. This is the windowed-sinc design
% fir1(15, 0.2) makes, written out because the Signal Processing Toolbox is
% not installed here: ideal low-pass response, Hamming window, unit DC gain.
order = 15;
wc = 0.2;
n = 0:order;
t = n - order / 2;                        % never zero for an odd order
ideal = sin(pi * wc * t) ./ (pi * t);
window = 0.54 - 0.46 * cos(2 * pi * n / order);
b = ideal .* window;
b = b / sum(b);
lp = round(b(:) * 32768);
lp = min(max(lp, -32768), 32767);
end

function s = checksum(y)
% The firmware's checksum: sum of (n+1) * (y(n) as an unsigned 16-bit value).
u = mod(double(y(:)), 65536);
s = uint64(sum((1:numel(u)).' .* u));
end

function s = toolboxes()
% Where fi comes from: Fixed-Point Designer's fi is present and licensed in
% this install even though ver does not list the toolbox.
s = sprintf('fi from %s, Fixed-Point Designer license %d', which('fi'), license('test', 'Fixed_Point_Toolbox'));
end

function fprintf_both(fid, varargin)
fprintf(varargin{:});
fprintf(fid, varargin{:});
end
