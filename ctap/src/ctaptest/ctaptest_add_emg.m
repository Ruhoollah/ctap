% Adds a burst of simulated EMG contamination to the EEG data
%   function eeg = ctaptest_add_EMG(eeg,ampl,t_start,dur,loc,rad,F)
%
% Args:
%   eeg: EEG struct
%   ampl <double>: EMG signal amplitude from 0 to max
%   t_start <double>: start time of the artifact (in seconds)
%   dur <double>: duration of the burst (in seconds)
%   loc <mat>: epicenter of the burst ([X Y Z])
%   rad <double>: radius of the EMG source
%   F <mat>: frequency band of the EMG burst ([lower_edge upper_edge transition_band])
%   timetemp <char>: temporal profile of EMG, linear or guassian
%   spacetemp <char>: spatial propagation (from loc) EMG profile, linear or log
%
% Returns:
%   eeg: EEG struct with EMG burst added. Artifact logged in 
%        eeg.CTAP.artifact.EMG   
function eeg = ctaptest_add_emg(eeg,ampl,t_start,dur,loc,rad,F,timetemp,spacetemp)

FS = 100; %sampling rate, in Hz

if nargin < 8
    timetemp = 'linear';
end
if nargin < 9
    spacetemp = 'linear';
end

% Find sample-index corresponding to start time
[~, start_idx] = min(abs(eeg.times - t_start * 1e3));

burst_dur = floor(eeg.srate * dur);
emg = randn(size(eeg.data, 1), burst_dur);
% This is the "temporal propagation template" 
switch timetemp
    case 'gauss'
        emg = emg .* repmat(gauss(burst_dur, 2), size(emg, 1), 1);
        % gauss() comes from eeglab (github version)
        
end

% Design the filter
wp  = [F(1) + F(3) F(2) - F(3)] ./ (.5 * eeg.srate);
ws  = [F(1) - F(3) F(2) + F(3)] ./ (.5 * eeg.srate);
rp = 1;
rs = 40;

[n, Wp] = cheb1ord(wp, ws, rp, rs);
[b, a] = cheby1(n, rp, Wp); %#ok<ASGLU>

fprintf(1,'\nAdding %0.2fs %0.2f-%0.2fHz (A=%0.2f) EMG burst at t=%0.2fs\n',...
            dur, F(1), F(2), ampl, t_start);

% Apply filter (maybe try eegfilt here)
%for k=1:size(emg,1)
%    emg(k,:) = filtfilt(b,a,emg(k,:)).*ampl;
%end

%ssx = eegfilt(emg,100,F(1),0,0,[],[],'fir1');
%ssx = eegfilt(ssx,100,0,F(2),0,[],[],'fir1');

%{
% disabled upon "too close to nyqvist" error:
warning('OFF', 'BACKTRACE')
% TODO: REPLACE CALLS TO eegfilt() WITH pop_eegfiltnew(), OR MATLAB'S
% filter() (BUT CAREFUL, BIOSIG ALSO HAS A FUNCTION CALLED filter()) -> 
% done, see code below.
ssx = eegfilt(emg, 100, F(1), 0, 0, [], 0, 'fir1');
ssx = eegfilt(ssx, 100, 0, F(2), 0, [], 0, 'fir1');
emg = ssx .* (ampl * 2);
warning('ON', 'BACKTRACE')
%}

% Filtering using EEGLAB firfilt -plugin
tbw = F(3); %transition band width, in Hz

% Band pass
cutoff = F(1:2); %cut-off frequencies, in Hz
m  = pop_firwsord('hamming', FS, tbw);
b  = firws(m, cutoff / (FS / 2),'band', windows('hamming', m + 1));
% Frequency response
% freqz(b, 1, 8192, FS)

emgtmp = create_eeg(emg, 'fs', FS);
emgtmp = firfilt(emgtmp, b);
emg = emgtmp.data .* (ampl * 2);

% Usage:
%   >> b = firws(m, f);
%   >> b = firws(m, f, w);
%   >> b = firws(m, f, t);
%   >> b = firws(m, f, t, w);
%
% Inputs:
%   m - filter order (mandatory even)
%   f - vector or scalar of cutoff frequency/ies (-6 dB;
%       pi rad / sample)
%
% Optional inputs:
%   w - vector of length m + 1 defining window {default blackman}
%   t - 'high' for highpass, 'stop' for bandstop filter {default low-/
%       bandpass}
%
% Output:
%   b - filter coefficients
%
% Example:
%   fs = 500; cutoff = 0.5; tbw = 1;
%   m  = pop_firwsord('hamming', fs, tbw);
%   b  = firws(m, cutoff / (fs / 2), 'high', windows('hamming', m + 1)); 


chc = [[eeg.chanlocs.X]' [eeg.chanlocs.Y]' [eeg.chanlocs.Z]'];
chd = eucl(chc, loc);

% This is the "spatial propagation template" 
switch spacetemp
    case 'linear'
        x = linspace(0, 5, 1000);% linear might not be good though
        
    case 'log'
        x = logspace(0, 5, 1000);
end
c = zeros(size(x));
c(x<rad) = linspace(1, 0, sum(x<rad));

emg = emg .* repmat(interp1(x, c, chd), 1, size(emg, 2));

% inject emg burst back into eeg-struct
eeg.data(:, start_idx:start_idx + burst_dur - 1)= ...
           eeg.data(:, start_idx:start_idx + burst_dur - 1) + single(emg);

eeg = eeg_checkset(eeg);

% Logging parameters
emg_params.time_window_smp = [start_idx start_idx + burst_dur - 1];
emg_params.amplitude = ampl;
emg_params.duration = burst_dur;
emg_params.location = loc;
emg_params.radius = rad;
emg_params.freqband = F;

% Update the CTAP.artifacts structure
if isfield(eeg.CTAP.artifact,'EMG')
    eeg.CTAP.artifact.EMG(end + 1) = emg_params;
else
    eeg.CTAP.artifact.EMG = emg_params;
end
