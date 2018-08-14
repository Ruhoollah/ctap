%% Linear CTAP script to clean SCCN data
% As referenced in the second CTAP article:
% Cowley BU and Korpela J (2018) Computational Testing for Automated 
% Preprocessing 2: Practical Demonstration of a System for Scientific 
% Data-Processing Workflow Management for High-Volume EEG. 
% Front. Neurosci. 12:236. doi: 10.3389/fnins.2018.00236
% 
% OPERATION STEPS
% # 1
% Install / download:
%   * Matlab R2016b or newer
%   * EEGLAB, latest version,
%       git clone https://adelorme@bitbucket.org/sccn_eeglab/eeglab.git
%   * CTAP,
%       git clone https://github.com/bwrc/ctap.git
%   * The 13 files of EEG data in .bdf format from the study 'Auditory Two-
%       Choice Response Task with an Ignored Feature Difference', available at
%       http://headit.ucsd.edu/studies/9d557882-a236-11e2-9420-0050563f2612

% # 2
% Set your working directory to CTAP root

% # 3
% Add EEGLAB and CTAP to your Matlab path. For a script to do this see 
% update_matlab_path_ctap.m at CTAP repository root: the directory containing
% 'ctap' and 'dependencies' folders.

% # 4
% Set up a data directory to contain the .bdf files. Pass the complete 
% path to this directory into the variable 'data_dir_in', below

% # 5
% On the Matlab console, execute >> runctap_manu2_basic


%% Setup MAIN parameters
% set the input directory where your data is stored
data_dir_in = '/home/ben/Benslab/CTAP/CTAPIIdata/testing';
% specify the file type of your data
data_type = '*.bdf';
% use sbj_filt to select all (or a subset) of available recordings
sbj_filt = setdiff(1:12, [3 7]);
% use ctapID to uniquely name the base folder of the output directory tree
ctapID = 'sccn-basic-pipe';
% use keyword 'all' to select all stepSets, or use some index
set_select = 'all';
% set the electrode for which to calculate and plot ERPs after preprocessing
erploc = 'A31';

% Runtime options for CTAP:
PREPRO = true;
STOP_ON_ERROR = true;
OVERWRITE_OLD_RESULTS = true;


%% Create the CONFIGURATION struct
% First, define step sets & their parameters: sbf_cfg() is written by the USER
[Cfg, ctap_args] = sbf_cfg(data_dir_in, ctapID);

% Select step sets to process
Cfg.pipe.runSets = set_select;

% Next, create measurement config (MC) based on folder, & select subject subset
[Cfg.MC, Cfg.pipe.runMeasurements] =...
    confilt_meas_dir(data_dir_in, data_type, sbj_filt);

% Assign arguments to the selected functions, perform various checks
Cfg = ctap_auto_config(Cfg, ctap_args);


%% Run the pipe
if PREPRO
    tic; %#ok<*UNRCH>
    CTAP_pipeline_looper(Cfg,...
                        'debug', STOP_ON_ERROR,...
                        'overwrite', OVERWRITE_OLD_RESULTS);
    toc;
end


%% Finally, obtain ERPs of known conditions from the processed data
%  Wrap it in try-catch because it is not inside the looper, and if we want to
%  run another script after this one, we don't want to crash on errors.
try
    ERPS = ctap_manu2_oddball_erps(Cfg, 'loc_label', erploc);
catch ME
    if STOP_ON_ERROR
        error('runctap_manu2_basic:erps', '%s', ME.message)
    else
        warning('runctap_manu2_basic:erps', '%s', ME.message)
    end
end

%cleanup the global workspace
clear PREPRO STOP_ON_ERROR OVERWRITE_OLD_RESULTS ctap_args


%% Subfunctions
% Pipe definition
function [Cfg, out] = sbf_cfg(project_root_folder, ID)


%% Define important directories and files
% Analysis ID
Cfg.id = ID;
% Directory where to locate project - in this case, just the same as input dir
Cfg.env.paths.projectRoot = project_root_folder;
% CTAP root dir named for the ID
Cfg.env.paths.ctapRoot = fullfile(Cfg.env.paths.projectRoot, Cfg.id);
% CTAP output goes into analysisRoot dir, here can be same as CTAP root
Cfg.env.paths.analysisRoot = Cfg.env.paths.ctapRoot;
% Channel location directory
Cfg.eeg.chanlocs = Cfg.env.paths.projectRoot;


%% Define other important stuff
Cfg.eeg.reference = {'average'};

% NOTE! EOG channel specification for artifact detection purposes. The
% HeadIT dataset did not use a traditional EOG montage with extra channels
% above and below the eye, as there were EEG channels mounted all the
% way down the forehead. Thus, EXG1-4 were mounted below and beside the
% eyes. We use H24 over EXG2 to approximate a bipolar lead for vertical EOG
Cfg.eeg.heogChannelNames = {'EXG1' 'EXG4'};
Cfg.eeg.veogChannelNames = {'H24' 'EXG2'};


%% Configure analysis pipe

%% Load and prepare - 
% Define the functions and parameters to load data & chanlocs, perform 
% 'safeguard' re-reference, find a blink subset to provide an IC template, 
% FIR filter, and compute an ICA decomposition.
% Parameters are grouped with functions for easier reading, but are a
% separate struct and can be defined elsewhere if preferred.
i = 1; %stepSet 1
stepSet(i).funH = { @CTAP_load_data,...
                    @CTAP_load_chanlocs,...
                    @CTAP_reref_data,... 
                    @CTAP_blink2event,...
                    @CTAP_fir_filter,...
                    @CTAP_run_ica };
stepSet(i).id = [num2str(i) '_load'];

out.load_chanlocs = struct(...
    'overwrite', true,...
    'delchan', 1,...
    'index_match', false);
out.load_chanlocs.field = {{{'EXG1' 'EXG2' 'EXG3' 'EXG4'} 'type' 'EOG'}...
     , {{'EXG5' 'EXG6' 'EXG7' 'EXG8' '1EX5' '1EX6' '1EX7' '1EX8'} 'type' 'NA'}};
out.load_chanlocs.tidy  = {{'type' 'FID'} {'type' 'NA'}};

out.fir_filter = struct(...
    'locutoff', 1);

out.run_ica = struct(...
    'method', 'fastica',...
    'overwrite', true);
out.run_ica.channels = {'EEG' 'EOG'};


%% Artefact correction -
% Before correcting anything, peek at the initial state of the data;
% Use ADJUST toolbox to detect ICs related to horizontal saccade, and remove; 
% Use the CTAP method to detect blink-related ICs, and filter them; 
% Use the variance method to detect bad channels, and interpolate them.
% Finally peek the data again, to compare with first peek & assess improvement
i = i+1;  %stepSet 2
stepSet(i).funH = { @CTAP_peek_data,...
                    @CTAP_detect_bad_comps,... %ADJUST for horizontal eye moves
                    @CTAP_reject_data,...
                    @CTAP_detect_bad_comps,... %detect blink related ICs
                    @CTAP_filter_blink_ica,...
                    @CTAP_detect_bad_channels,...%adjust the variance thresholds!
                    @CTAP_reject_data,...
                    @CTAP_interp_chan,...
                    @CTAP_peek_data };
stepSet(i).id = [num2str(i) '_artifact_correction'];

out.peek_data = struct(...
    'secs', [10 30],... %start few seconds after data starts
    'peekStats', true,... %get statistics for each peek!
    'overwrite', false,...
    'plotAllPeeks', false,...
    'savePeekData', true,...
    'savePeekICA', true);

out.detect_bad_comps = struct(...
    'method', {'adjust' 'blink_template'},...
    'adjustarg', {'horiz' ''});

out.detect_bad_channels = struct(...
    'method', 'variance',...
    'channelType', {'EEG'});


%% Store to Cfg
Cfg.pipe.stepSets = stepSet; % return all step sets inside Cfg struct

end
