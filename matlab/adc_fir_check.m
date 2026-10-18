function adc_fir_check(tone_csv, two_tone_csv, coeff_file, log_file)
%ADC_FIR_CHECK Analysis of the ADC-model bench (tb/unit/fir_adc_tb.sv).
%
%   adc_fir_check(tone_csv, two_tone_csv, coeff_file, log_file) reads the two
%   bench outputs (columns n, vin, code, y) and the Q15 low-pass coefficients,
%   and checks:
%     - both runs: the hardware filter output y equals fir_model(coeffs, code)
%       bit for bit;
%     - TEST=0 (one tone, ideal 12-bit ADC): SNR from a 1024-point FFT is
%       within 1 dB of the ideal 6.02*12 + 1.76 dB, scaled to the tone level;
%     - TEST=1 (two tones, ADC with noise, offset and gain error): the filter's
%       measured gain at each tone (sine fits to the input codes and the output,
%       after the 15-sample start-up) is within 0.1 dB of the gain computed from
%       the coefficients in the pass band and within 1 dB in the stop band.
%   Errors stop the script; results go to log_file and the console.
coeff = read_numbers(coeff_file, 0);
log = fopen(log_file, 'w');
cleanup = onCleanup(@() fclose(log));
say = @(varargin) both(log, varargin{:});
bits = 12;
N = 1024;

% ------------------------------------------------------ TEST=0, one tone
d = read_numbers(tone_csv, 1);
code = d(:, 3); y = d(:, 4);
check_bitexact(say, 'tone', coeff, code, y);
x = code / 32768;                                   % Q15 to +-1.0 full scale
X = abs(fft(x)).^2;
k = 31;                                             % tone bin (0-based); MATLAB index k+1
signal = X(k+1) + X(N-k+1);
noise = sum(X(2:N/2+1)) * 2 - signal - X(N/2+1);    % every bin but DC and the tone, both halves
level = 10 * log10(signal / (N^2 / 2));             % dBFS for a full-scale sine = 0
snr = 10 * log10(signal / noise);
ideal = 6.02 * bits + 1.76 + level;
enob = (snr - 1.76 - level) / 6.02;
say('ADC_TONE level_dbfs=%.2f snr_db=%.2f ideal_db=%.2f enob=%.2f\n', level, snr, ideal, enob);
if abs(snr - ideal) > 1
    error('adc_fir_check:snr', 'SNR %.2f dB is not within 1 dB of %.2f dB', snr, ideal);
end

% -------------------------------------------- TEST=1, two tones, filtered
d = read_numbers(two_tone_csv, 1);
code = d(:, 3); y = d(:, 4);
check_bitexact(say, 'two_tone', coeff, code, y);
offset_lsb = mean(code) / 2^(16 - bits);
say('ADC_TWO_TONE mean_code_lsb=%.2f (offset 1.5 mV is %.2f LSB before the 0.995 gain)\n', ...
    offset_lsb, 1.5e-3 / (2 / 2^bits));
h = coeff(:) / 32768;
for tone = [31 409]
    f = tone / N;                                   % cycles per sample
    predicted = abs(sum(h .* exp(-1i * 2 * pi * f * (0:numel(h)-1).')));
    keep = (numel(h):N).';                          % after the filter's start-up
    a_in = sine_amplitude(code(keep), f, keep - 1);
    a_out = sine_amplitude(y(keep), f, keep - 1);
    measured_db = 20 * log10(a_out / a_in);
    predicted_db = 20 * log10(predicted);
    say('FIR_TONE bin=%d f_over_fs=%.4f input_dbfs=%.2f output_dbfs=%.2f gain_db=%.2f predicted_db=%.2f\n', ...
        tone, f, 20 * log10(a_in / 32768), 20 * log10(a_out / 32768), measured_db, predicted_db);
    tolerance = 0.1 + 0.9 * (predicted_db < -20);   % stop band: the output is a few LSB
    if abs(measured_db - predicted_db) > tolerance
        error('adc_fir_check:gain', 'gain at bin %d is %.2f dB, expected %.2f dB', tone, measured_db, predicted_db);
    end
end
say('ADC_FIR_CHECK_PASS\n');
end

function check_bitexact(say, name, coeff, code, y)
model = double(fir_model(coeff, code));
mismatches = sum(model ~= y);
say('FIR_ADC_BITEXACT run=%s samples=%d mismatches=%d\n', name, numel(y), mismatches);
if mismatches
    error('adc_fir_check:bitexact', '%s: %d outputs differ from fir_model', name, mismatches);
end
end

function a = sine_amplitude(v, f, n)
% Least-squares fit of c + p*cos + q*sin at a known frequency.
A = [ones(size(n)) cos(2 * pi * f * n) sin(2 * pi * f * n)];
coef = A \ v;
a = hypot(coef(2), coef(3));
end

function d = read_numbers(path, header_lines)
% Numeric CSV or one-column text, without readmatrix's type detection.
fid = fopen(path, 'r');
for i = 1:header_lines, fgetl(fid); end
first = fgetl(fid);
columns = numel(strsplit(first, ','));
frewind(fid);
for i = 1:header_lines, fgetl(fid); end
c = textscan(fid, repmat('%f', 1, columns), 'Delimiter', ',');
fclose(fid);
d = [c{:}];
end

function both(fid, varargin)
fprintf(varargin{:});
fprintf(fid, varargin{:});
end
