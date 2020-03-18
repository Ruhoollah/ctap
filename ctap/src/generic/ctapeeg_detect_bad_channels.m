function [EEG, varargout] = ctapeeg_detect_bad_channels(EEG, varargin)
%CTAPEEG_DETECT_BAD_CHANNELS use some given method to find bad channels
%
% Syntax:
%   EEG = ctapeeg_detect_bad_channels(EEG, varargin)
%
% Input:
%   'EEG'         EEG file to process
% varargin:
%   'outdir'      output directory, default = pwd
%   'channels'    [1:k] _integer_, choose the channels to measure for badness 
%                 Default = channels of type=='EEG'
%   'method'      choose method from options. Default depends on number of
%                 channels, chans < 32 = rejspec, chans > 32 = maha_fast
%                   'maha_fast' - integrate FASTER indices by Mahalanobis dist &
%                               'factorVal'*mad thresholding
%                   'faster' - recursive use of FASTER indices
%                   'recufast' - recursive use of FASTER indices
%                   'variance' - single use of variance
%                   'recuvari' - recursive use of variance
%                   'rejspec' - EEGLAB's func, reject bad channels by spectra
%
%   FOR any method using FASTER (with 'fast' in the name)
%   'orig_ref'    reference channel(s) of data when passed
%                 default = channels of type=='REF' or EEG.CTAP.reference
%   'refChannel'  cell of strings, reference channel name for FASTER
%                 Default = {'Fz','C21'}
%                 Fz is used by the authors of FASTER since it is common 
%                 to 32, 64 and 128 channel setups.
%   'match_measures' choice of measures to use, default all from the list:
%                    'chanCorrelation', 'variance', 'hurst'
%                    Partial string matches (down to 1 letter) will also work
%
%   FOR method Mahalanobis dist & 'factorVal'*mad thresholding
%   'factorVal'   factor to multiply the outlier detection threshold
%                 Default = 3
%
%   FOR recursive FASTER method 'recufast'
%   'report'      boolean, produce/save visuals of FASTER iters
%                 Default = false
%
%   FOR recursive 'variance' method or FASTER 'recufast'
%   'bounds'      sigma thresholds for bad channel detection with recufast
%                 and variance methods, default=[-3 3]
%   'iters'       iterations to use in recufast and variance methods. If
%                 set to 0 these methods become nonrecursive
%                 Default = 0
%
%   FOR 'rejspec' reject channel spectra method
%   'freq_lim'    [m 2] integer array, each min max row is frequency limits, 
%                 where each row defines a different set of limits. 
%                 Default=[0 10; 35 Nyquist]
%   'std_thresh'  [m 1] integer array, each row is positive threshold in 
%                 terms of standard deviation, row count must match freqLim
%                 Default = [5; 3]
%
% Output:
%   'EEG'         struct, modified input EEG
% varargout:
%   {1}           struct, the complete list of arguments actually used
%   {2}           struct, 3 fields:
%                 .chans - channel names of bad channels
%                 .scores - table with scores for badness of channels
%                 .method_data - optional method specific data
%
% NOTE
%
% CALLS    eeglab functions, recurseBadChan(), eeg_detect_bad_channels()
%
% REFERENCE:
%   Delorme, A., Sejnowski, T., & Makeig, S. (2007). Enhanced detection of 
%   artifacts in EEG data using higher-order statistics and independent 
%   component analysis. NeuroImage, 34(4), 1443-9.
%
% Version History:
% 20.10.2014 Created (Benjamin Cowley, FIOH)
%
% Copyright(c) 2015 FIOH:
% Benjamin Cowley (Benjamin.Cowley@ttl.fi), Jussi Korpela (jussi.korpela@ttl.fi)
%
% This code is released under the MIT License
% http://opensource.org/licenses/mit-license.php
% Please see the file LICENSE for details.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


faster_vars = {'chanCorrelation' 'variance' 'hurst'};
sbf_check_input() % parse the varargin, set defaults
EEGtmp = EEG;


%% Temporarily re-reference to given single reference point
if ~isempty(strfind(Arg.method, 'fast'))
    % Re-reference for FASTER
    if ~isempty(Arg.refChannel)
        EEG = ctapeeg_reref_data(EEG, 'ref', Arg.refChannel);
    else
        varargout{2} = myReport('FAIL :: reference channel not found ...');
    end
end

% Remove channel baselines
[EEG.data, ~] = rmbase(EEG.data);

result = struct('method_data', '', 'scores', []);


%% Call the CHOSEN method
switch Arg.method
    case 'faster'
        % Get the 3 magic FASTER properties for each channel
        chprp = channel_properties(EEG, Arg.channels, Arg.refChannel);
        % Choose which properties to match on
        if iscell(Arg.match_measures)
            match_measures = startsWith(faster_vars, Arg.match_measures);
        end
        if isscalar(Arg.bounds)
            Arg.bounds = [(abs(Arg.bounds) * -1) abs(Arg.bounds)];
        end
        % identify the bad channels by z-score thresholding on each measure
        rej_opt = struct('z', Arg.bounds, 'measures', match_measures);
        chbad = min_z(chprp, Arg.match_logic, rej_opt);
        bad_chan_match = Arg.channels(chbad');
        % build the output table
        result.scores =...
            table(chprp(:,1), chprp(:,2), chprp(:,3)...
            , 'RowNames', {EEG.chanlocs(Arg.channels).labels}'...
            , 'VariableNames', faster_vars);


    case 'recufast'
        recu_out = recufast_badness_detector(...
                  EEG, struct(), Arg.channels, Arg.bounds, Arg.iters, 'chan',...
                  'outdir', Arg.outdir, 'report', Arg.report);
        bad_chan_match = recu_out.bad_bin(2,:) > 0;
        result.scores = table(recu_out.bad_bin(2, :)' ...
            , 'RowNames', {EEG.chanlocs(Arg.channels).labels}'...
            , 'VariableNames', {'recursiveFASTER'});


    case 'maha_fast'
        [bad_chan_match, ~, scores] = eeg_detect_bad_channels(EEG...
                                , EEG.chanlocs(Arg.refChannel(1)).labels...
                                , 'channels', Arg.channels...
                                , 'factorVal', Arg.factorVal);
        result.scores = table(scores(:)...
            , 'RowNames', {EEG.chanlocs(Arg.channels).labels}'...
            , 'VariableNames', {'maha_fast'});


    case 'variance'
        res = vari_bad_chans(EEG, Arg.channels, Arg.bounds...
                            , 'take_worst_n', Arg.take_worst_n...
                            , 'plot', Arg.plot_detections);
        bad_chan_match = res.dead | res.loose;
        result.scores = table(res.variance ...
            , 'RowNames', {EEG.chanlocs(Arg.channels).labels}'...
            , 'VariableNames', {'variance'});
        result.method_data.th = res.th;


    case 'recuvari'
        recu_out = recurse_variance_bad_chans(...
                    EEG, struct, Arg.channels, Arg.bounds, Arg.iters,...
                    'outdir', Arg.outdir);
        bad_chan_match = recu_out.badchbin(2,:) > 0;
        result.scores = table(recu_out.badchbin(2,:)' ...
            , 'RowNames', {EEG.chanlocs(Arg.channels).labels}'...
            , 'VariableNames', {'variance'});


    case 'rejspec'
        [~, bad_chan_match] = pop_rejchanspec( EEG,...
                'elec', Arg.channels,...
                'freqlims', Arg.freq_lim,...
                'stdthresh', [Arg.std_thresh*-1 Arg.std_thresh]);
        bad_chan_match = ismember(Arg.channels, bad_chan_match);
        result.scores = table(uint8(bad_chan_match(:))...
            , 'RowNames', {EEG.chanlocs(Arg.channels).labels}'...
            , 'VariableNames', {'spectralStDev'});
end


%% return the bad channel names...create data frame
result.chans = {EEG.chanlocs(Arg.channels(bad_chan_match)).labels};

if ~istable(result.scores)
    error('ctapeeg_detect_bad_chans:bad_output',...
        'Bad chan scores by ''%s'' must be in table format', Arg.method)
end


%% Report parameters used and result
Arg.channels = {EEG.chanlocs(Arg.channels).labels};
varargout{1} = Arg;
varargout{2} = result;
% Return EEG back to original
EEG = EEGtmp;


%% Subfunctions
    function sbf_check_input() % parse the varargin, set defaults
        % Unpack and store varargin
        if isempty(varargin)
            vargs = struct;
        elseif numel(varargin) > 1 %(assume parameter/name pairs)
            vargs = cell2struct(varargin(2:2:end), varargin(1:2:end), 2);
        else
            vargs = varargin{1}; %(assume a struct wrapped in a cell)
        end
        
        %general channel-related parameters
        Arg.plot_detections = true;
        Arg.take_worst_n = 0;

        try Arg.method = vargs.method;
        catch
            error('ctapeeg_detect_bad_channels:bad_param', ...
                'It is necessary to define the chosen ''method'': see help')
        end
        
        switch Arg.method
            case 'recufast'
                Arg.report = false;
                Arg.bounds = [-3 3];
                Arg.iters  = 10;
                Arg.outdir = '';
                
            case 'faster'
                Arg.bounds = [-2 2];
                Arg.match_logic = @all;
                Arg.match_measures = faster_vars;

            case 'maha_fast'
                Arg.factorVal = 3;

            case 'recuvari'
                Arg.bounds = [-3 3];
                Arg.iters  = 10;
                Arg.outdir = '';

            case 'variance'
                Arg.bounds = 3; % MEDIAN +- 3*MAD

            case 'rejspec'
                Arg.freq_lim = [0 5]; 
                Arg.std_thresh = 3;

            otherwise
                error('ctapeeg_detect_bad_channels:bad_method',...
                    'Method %s not recognised, aborting', Arg.method)
        end
        
        % Arg fields are canonical, vargs values are canonical: intersect-join
        Arg = intersect_struct(Arg, vargs);
        
        % If desired, the default values can be changed below:
        try Arg.channels = get_eeg_inds(EEG, vargs.channels);
        catch
            Arg.channels = get_eeg_inds(EEG, 'EEG');
        end

        if ~isempty(strfind(Arg.method, 'fast'))
            % get frontal vertex
            try Arg.refChannel = get_refchan_inds(EEG, vargs.refChannel);
            catch
                Arg.refChannel = get_refchan_inds(EEG, 'frontal');
            end
            % Define default 'original' reference
            try Arg.orig_ref = vargs.orig_ref;
            catch
                Arg.orig_ref = get_refchan_inds(EEG, 'asis');
            end
        end
    end

end % ctapeeg_detect_bad_channels()
