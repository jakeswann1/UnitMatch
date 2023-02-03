function  [UniqueID, MatchTable] = UnitMatch(clusinfo,param,sp)
%% Match units on neurophysiological evidence
% Input:
% - clusinfo (this is phy output, see also prepareinfo/spikes toolbox)
% - AllDecompPaths: cell struct with paths for individual recording
% sessions (Decompressed)
% - param: parameters for ephys extraction
% - sp: kilosort output struct

% Output:
% - UniqueID (Units that are found to be a match are given the same
% UniqueID. This UniqueID can be used for further analysis
% - MatchTable: Probability, rank score and cross-correlation correlation
% (Fingerprint correlation) of all possible unit pairs

% Matching occurs on:
% - Waveform Similarity: Correlation and errors
% - Projected location difference (Centroid): distance and direction
% - Amplitude differences
% - Spatial decay (decrease in signal over space)

% fine tuning the initial training set for matching:
% - cross-correlation finger prints --> units that are the same are likely
% to correlate in a similar way with other units 

% Contributions:
% Enny van Beest (2022)
% Célian Bimbard (2022)

%% Parameters - tested on these values, but feel free to try others
global stepsize
stepsize = 0.01; % Of probability distribution
MakePlotsOfPairs = 1; % Plots all pairs for inspection
Scores2Include = {'AmplitudeSim','WavformSim','WVCorr','LocAngleSim','spatialdecaySim','LocDistSim'}; %
IncludeSpatialInitially = 1; % if 1 we include spatial distance from the start, if 0 only from the naive Bayes part
TakeChannelRadius = 75; %in micron around max channel
maxdist = 200; % Maximum distance at which units are considered as potential matches
binsz = 0.01; % Binsize in time (s) for the cross-correlation fingerprint. We recommend ~2-10ms time windows
RemoveRawWavForms = 0; %Remove averaged waveforms again to save space --> Currently only two averages saved so shouldn't be a problem to keep it, normally speaking
% Scores2Include = {'WavformSimilarity','LocationCombined','spatialdecayDiff','AmplitudeDiff'};%}
MakeOwnNaiveBayes = 1; % if 0, use standard matlab version, which assumes normal distributions --> not recommended
ApplyExistingBayesModel = 0; %If 1, use probability distributions made available by us
maxrun = 1; % This is whether you want to use Bayes' output to create a new potential candidate set to optimize the probability distributions. Probably we don't want to keep optimizing?, as this can be a bit circular (?)
drawmax = 20; % Maximum number of drawed matches (otherwise it takes forever!)
%% Read in from param
channelpos = param.channelpos;
RunPyKSChronicStitched = param.RunPyKSChronicStitched;
SaveDir = param.SaveDir;
AllDecompPaths = param.AllDecompPaths;
AllRawPaths = param.AllRawPaths;
param.nChannels = length(param.channelpos)+1; %First assume there's a sync channel as well.
sampleamount = param.sampleamount; %500; % Nr. waveforms to include
spikeWidth = param.spikeWidth; %83; % in sample space (time)
UseBombCelRawWav = param.UseBombCelRawWav; % If Bombcell was also applied on this dataset, it's faster to read in the raw waveforms extracted by Bombcell

%% Extract all cluster info 
AllClusterIDs = clusinfo.cluster_id;
nses = length(AllDecompPaths);
OriginalClusID = AllClusterIDs; % Original cluster ID assigned by KS
UniqueID = 1:length(AllClusterIDs); % Initial assumption: All clusters are unique
Good_Idx = find(clusinfo.Good_ID); %Only care about good units at this point
GoodRecSesID = clusinfo.RecSesID(Good_Idx);

% Define day stucture
recsesAll = clusinfo.RecSesID;
recsesGood = recsesAll(Good_Idx);
[X,Y]=meshgrid(recsesAll(Good_Idx));
nclus = length(Good_Idx);
ndays = length(unique(recsesAll));
x = repmat(GoodRecSesID,[1 numel(GoodRecSesID)]);
SameSesMat = x == x';
% SameSesMat = arrayfun(@(X) cell2mat(arrayfun(@(Y) GoodRecSesID(X)==GoodRecSesID(Y),1:nclus,'Uni',0)),1:nclus,'Uni',0);
% SameSesMat = cat(1,SameSesMat{:});
OriSessionSwitch = cell2mat(arrayfun(@(X) find(recsesAll==X,1,'first'),1:ndays,'Uni',0));
OriSessionSwitch = [OriSessionSwitch nclus+1];
SessionSwitch = arrayfun(@(X) find(GoodRecSesID==X,1,'first'),1:ndays,'Uni',0);
SessionSwitch(cellfun(@isempty,SessionSwitch))=[];
SessionSwitch = [cell2mat(SessionSwitch) nclus+1];

%% Extract raw waveforms 
% This script does the actual extraction
ExtractAndSaveAverageWaveforms(clusinfo,param,sp)
%% Extract parameters used in UnitMatch

% Initialize
ProjectedLocation = nan(2,nclus,2);
ProjectedLocationPerTP = nan(2,nclus,spikeWidth,2);
ProjectedWaveform = nan(spikeWidth,nclus,2); % Just take waveform on maximal channel
PeakTime = nan(nclus,2); % Peak time first versus second half
MaxChannel = nan(nclus,2); % Max channel first versus second half
waveformduration = nan(nclus,2); % Waveformduration first versus second half
Amplitude = nan(nclus,2); % Maximum (weighted) amplitude, first versus second half

spatialdecay = nan(nclus,2); % how fast does the unit decay across space, first versus second half
WaveIdx = nan(nclus,spikeWidth,2);
%Calculate how many channels are likely to be included
fakechannel = [channelpos(1,1) nanmean(channelpos(:,2))];
ChanIdx = find(cell2mat(arrayfun(@(Y) norm(fakechannel-channelpos(Y,:)),1:size(channelpos,1),'UniformOutput',0))<TakeChannelRadius); %Averaging over 10 channels helps with drift
% MultiDimMatrix = nan(spikeWidth,length(ChanIdx),nclus,2); % number time points (max), number of channels (max?), per cluster and cross-validated

% Take geographically close channels (within 50 microns!), not just index!
timercounter = tic;
fprintf(1,'Extracting raw waveforms. Progress: %3d%%',0)
for uid = 1:nclus
    fprintf(1,'\b\b\b\b%3.0f%%',uid/nclus*100)
    load(fullfile(SaveDir,'UnitMatchWaveforms',['Unit' num2str(UniqueID(Good_Idx(uid))) '_RawSpikes.mat']))

    % Extract unit parameters -
    % Cross-validate: first versus second half of session
    for cv = 1:2
        % Find maximum channels:
        [~,MaxChannel(uid,cv)] = nanmax(nanmax(abs(spikeMap(35:70,:,cv)),[],1));

        % Extract channel positions that are relevant and extract mean location
        ChanIdx = find(cell2mat(arrayfun(@(Y) norm(channelpos(MaxChannel(uid,cv),:)-channelpos(Y,:)),1:size(channelpos,1),'UniformOutput',0))<TakeChannelRadius); %Averaging over 10 channels helps with drift
        Locs = channelpos(ChanIdx,:);

        % Mean location:
        mu = sum(repmat(nanmax(abs(spikeMap(:,ChanIdx,cv)),[],1),size(Locs,2),1).*Locs',2)./sum(repmat(nanmax(abs(nanmean(spikeMap(:,ChanIdx,cv),3)),[],1),size(Locs,2),1),2);
        ProjectedLocation(:,uid,cv)=mu;

        %     % Mean waveform - first extract the 'weight' for each channel, based on
        %     % how close they are to the projected location (closer = better)
        Distance2MaxChan = sqrt(nansum(abs(Locs-channelpos(MaxChannel(uid,cv),:)).^2,2));
        % Difference in amplitude from maximum amplitude
        spdctmp = (nanmax(abs(spikeMap(:,MaxChannel(uid,cv),cv)),[],1)-nanmax(abs(spikeMap(:,ChanIdx,cv)),[],1))./nanmax(abs(spikeMap(:,MaxChannel(uid,cv),cv)),[],1);
        % Spatial decay (average oer micron)
        spatialdecay(uid,cv) = nanmean(spdctmp./Distance2MaxChan');

        % Use this waveform - weighted average across channels:
        Distance2MaxProj = sqrt(nansum(abs(Locs-ProjectedLocation(:,uid,cv)').^2,2));
        weight = (TakeChannelRadius-Distance2MaxProj)./TakeChannelRadius;
        ProjectedWaveform(:,uid,cv) = nansum(spikeMap(:,ChanIdx,cv).*repmat(weight,1,size(spikeMap,1))',2)./sum(weight);

        % Find significant timepoints
        wvdurtmp = find(abs(ProjectedWaveform(:,uid,cv))>abs(nanmean(ProjectedWaveform(1:20,uid,cv)))+2.5*nanstd(ProjectedWaveform(1:20,uid,cv))); % More than 2. std from baseline

        if isempty(wvdurtmp)
            wvdurtmp = 20:80;
        end
        % Peak Time
        [~,PeakTime(uid,cv)] = nanmax(abs([nan; diff(ProjectedWaveform(wvdurtmp(1):wvdurtmp(end),uid,cv))]));

        PeakTime(uid,cv) = PeakTime(uid,cv)+wvdurtmp(1)-1;
        Peakval = ProjectedWaveform(PeakTime(uid,cv),uid,cv);
        Amplitude(uid,cv) = Peakval;

        % Full width half maximum
        wvdurtmp = find(sign(Peakval)*ProjectedWaveform(:,uid,cv)>0.5*sign(Peakval)*Peakval);
        waveformduration(uid,cv) = length(wvdurtmp);
        % Mean Location per individual time point:
        ProjectedLocationPerTP(:,uid,wvdurtmp,cv) = cell2mat(arrayfun(@(tp) sum(repmat(abs(spikeMap(tp,ChanIdx,cv)),size(Locs,2),1).*Locs',2)./sum(repmat(abs(spikeMap(tp,ChanIdx,cv)),size(Locs,2),1),2),wvdurtmp','Uni',0));
        WaveIdx(uid,1:size(wvdurtmp),cv) = wvdurtmp;
        % Save spikes for these channels
        %         MultiDimMatrix(wvdurtmp,1:length(ChanIdx),uid,cv) = nanmean(spikeMap(wvdurtmp,ChanIdx,wavidx),3);

    end
end

fprintf('\n')
disp(['Extracting raw waveforms and parameters took ' num2str(round(toc(timercounter)./60)) ' minutes for ' num2str(nclus) ' units'])

%% Metrics
% PeakTime = nan(nclus,2); % Peak time first versus second half
% MaxChannel = nan(nclus,2); % Max channel first versus second half
% waveformduration = nan(nclus,2); % Waveformduration first versus second half
% spatialdecay = nan(nclus,2); % how fast does the unit decay across space, first versus second half
disp('Computing Metric similarity between pairs of units...')
timercounter = tic;
x1 = repmat(PeakTime(:,1),[1 numel(PeakTime(:,1))]);
x2 = repmat(PeakTime(:,2),[1 numel(PeakTime(:,2))]);
PeakTimeSim = abs(x1 - x2');
% PeakTimeSim = arrayfun(@(uid) cell2mat(arrayfun(@(uid2) abs(PeakTime(uid,1)-PeakTime(uid2,2)),1:nclus,'Uni',0)),1:nclus,'Uni',0);
% PeakTimeSim=cat(1,PeakTimeSim{:});
%Normalize between 0 and 1 (values that make sense after testing, without having outliers influence this)
PeakTimeSim =1-PeakTimeSim./quantile(PeakTimeSim(:),0.99);
PeakTimeSim(PeakTimeSim<0)=0;

% can't find much better for this one
waveformTimePointSim = nan(nclus,nclus);
for uid = 1:nclus
    for uid2 = 1:nclus
        waveformTimePointSim(uid,uid2) = sum(ismember(WaveIdx(uid,:,1),WaveIdx(uid2,:,2)))./sum(~isnan(WaveIdx(uid,:,1)));
    end
end
% waveformTimePointSim = arrayfun(@(uid) cell2mat(arrayfun(@(uid2) sum(ismember(WaveIdx(uid,:,1),WaveIdx(uid2,:,2)))./sum(~isnan(WaveIdx(uid,:,1))),1:nclus,'Uni',0)),1:nclus,'Uni',0);
% waveformTimePointSim = cat(1,waveformTimePointSim{:});

x1 = repmat(spatialdecay(:,1),[1 numel(spatialdecay(:,1))]);
x2 = repmat(spatialdecay(:,2),[1 numel(spatialdecay(:,2))]);
spatialdecaySim = abs(x1 - x2');
% spatialdecaySim = arrayfun(@(uid) cell2mat(arrayfun(@(uid2) abs(spatialdecay(uid,1)-spatialdecay(uid2,2)),1:nclus,'Uni',0)),1:nclus,'Uni',0);
% spatialdecaySim = cat(1,spatialdecaySim{:});
% Make (more) normal
spatialdecaySim = sqrt(spatialdecaySim);
spatialdecaySim = 1-((spatialdecaySim-nanmin(spatialdecaySim(:)))./(quantile(spatialdecaySim(:),0.99)-nanmin(spatialdecaySim(:))));
spatialdecaySim(spatialdecaySim<0)=0;

% Ampitude difference
x1 = repmat(Amplitude(:,1),[1 numel(Amplitude(:,1))]);
x2 = repmat(Amplitude(:,2),[1 numel(Amplitude(:,2))]);
AmplitudeSim = abs(x1 - x2');
% AmplitudeSim = arrayfun(@(uid) cell2mat(arrayfun(@(uid2) abs(Amplitude(uid,1)-Amplitude(uid2,2)),1:nclus,'Uni',0)),1:nclus,'Uni',0);
% AmplitudeSim = cat(1,AmplitudeSim{:});
% Make (more) normal
AmplitudeSim = sqrt(AmplitudeSim);
AmplitudeSim = 1-((AmplitudeSim-nanmin(AmplitudeSim(:)))./(quantile(AmplitudeSim(:),.99)-nanmin(AmplitudeSim(:))));
AmplitudeSim(AmplitudeSim<0)=0;

disp(['Calculating other metrics took ' num2str(round(toc(timercounter))) ' seconds for ' num2str(nclus) ' units'])

%% Waveform similarity
disp('Computing waveform similarity between pairs of units...')
timercounter = tic;
% Normalize between 0 and 1
ProjectedWaveformNorm = ProjectedWaveform(35:70,:,:);
ProjectedWaveformNorm = (ProjectedWaveformNorm-nanmin(ProjectedWaveformNorm,[],1))./(nanmax(ProjectedWaveformNorm,[],1)-nanmin(ProjectedWaveformNorm,[],1));
x1 = repmat(ProjectedWaveformNorm(:,:,1),[1 1 size(ProjectedWaveformNorm,2)]);
x2 = permute(repmat(ProjectedWaveformNorm(:,:,2),[1 1 size(ProjectedWaveformNorm,2)]),[1 3 2]);
RawWVMSE = squeeze(nanmean((x1 - x2).^2));
% RawWVMSE = arrayfun(@(uid) cell2mat(arrayfun(@(uid2) nanmean((ProjectedWaveformNorm(:,uid,1)-ProjectedWaveformNorm(:,uid2,2)).^2),1:nclus,'Uni',0)),1:nclus,'Uni',0);
% RawWVMSE = cat(1,RawWVMSE{:});
WVCorr = corr(ProjectedWaveform(35:70,:,1),ProjectedWaveform(35:70,:,2));
% WVCorr = arrayfun(@(uid) cell2mat(arrayfun(@(uid2) corr(ProjectedWaveform(35:70,uid,1),ProjectedWaveform(35:70,uid2,2)),1:nclus,'Uni',0)),1:nclus,'Uni',0);
% WVCorr = cat(1,WVCorr{:});

% Make WVCorr a normal distribution
WVCorr = atanh(WVCorr);
WVCorr = (WVCorr-nanmin(WVCorr(:)))./(nanmax(WVCorr(:))-nanmin(WVCorr(:)));

% sort of Normalize distribution
RawWVMSENorm = sqrt(RawWVMSE);
WavformSim = (RawWVMSENorm-nanmin(RawWVMSENorm(:)))./(quantile(RawWVMSENorm(:),0.99)-nanmin(RawWVMSENorm(:)));
WavformSim = 1-WavformSim;
WavformSim(WavformSim<0) = 0;

disp(['Calculating waveform similarity took ' num2str(round(toc(timercounter))) ' seconds for ' num2str(nclus) ' units'])
figure('name','Waveform similarity measures')
subplot(1,3,1)
h=imagesc(WVCorr);
title('Waveform correlations')
xlabel('Unit Y')
ylabel('Unit Z')
hold on
arrayfun(@(X) line([SessionSwitch(X) SessionSwitch(X)],get(gca,'ylim'),'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
arrayfun(@(X) line(get(gca,'xlim'),[SessionSwitch(X) SessionSwitch(X)],'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
colormap(flipud(gray))
colorbar
makepretty

subplot(1,3,2)
h=imagesc(WavformSim);
title('Waveform mean squared errors')
xlabel('Unit Y')
ylabel('Unit Z')
hold on
arrayfun(@(X) line([SessionSwitch(X) SessionSwitch(X)],get(gca,'ylim'),'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
arrayfun(@(X) line(get(gca,'xlim'),[SessionSwitch(X) SessionSwitch(X)],'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
colormap(flipud(gray))
colorbar
makepretty

subplot(1,3,3)
h=imagesc((WVCorr+WavformSim)/2);
title('Average Waveform scores')
xlabel('Unit Y')
ylabel('Unit Z')
hold on
arrayfun(@(X) line([SessionSwitch(X) SessionSwitch(X)],get(gca,'ylim'),'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
arrayfun(@(X) line(get(gca,'xlim'),[SessionSwitch(X) SessionSwitch(X)],'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
colormap(flipud(gray))
colorbar
makepretty

%% Location differences between pairs of units: - This is done twice to account for large drift between sessions
flag=0;
while flag<2
    figure('name','Projection locations all units')
    scatter(channelpos(:,1),channelpos(:,2),10,[0 0 0],'filled')
    hold on
    scatter(nanmean(ProjectedLocation(1,:,:),3),nanmean(ProjectedLocation(2,:,:),3),10,GoodRecSesID)
    colormap jet
    makepretty
    xlabel('XPos (um)')
    ylabel('YPos (um)')
    xlim([min(channelpos(:,1))-50 max(channelpos(:,1))+50])
    drawnow

    disp('Computing location distances between pairs of units...')
    timercounter = tic;
    LocDist = sqrt((ProjectedLocation(1,:,1)'-ProjectedLocation(1,:,2)).^2 + ...
        (ProjectedLocation(2,:,1)'-ProjectedLocation(2,:,2)).^2);
    % LocDist = arrayfun(@(X) cell2mat(arrayfun(@(Y) pdist(cat(2,ProjectedLocation(:,X,1),ProjectedLocation(:,Y,2))'),1:nclus,'Uni',0)),1:nclus,'Uni',0);
    % LocDist = cat(1,LocDist{:}); % Normal difference

    disp('Computing location distances between pairs of units, per individual time point of the waveform...')
    % Difference in distance at different time points
    x1 = repmat(squeeze(ProjectedLocationPerTP(:,:,:,1)),[1 1 1 size(ProjectedLocationPerTP,2)]);
    x2 = permute(repmat(squeeze(ProjectedLocationPerTP(:,:,:,2)),[1 1 1 size(ProjectedLocationPerTP,2)]),[1 4 3 2]);
    LocDistSign = sqrt(sum((x1-x2).^2,1));
    LocDistSim = squeeze(nanmean(LocDistSign,3));
    % LocDistSign = arrayfun(@(uid) arrayfun(@(uid2)  cell2mat(arrayfun(@(X) pdist(cat(2,squeeze(ProjectedLocationPerTP(:,uid,X,1)),squeeze(ProjectedLocationPerTP(:,uid2,X,2)))'),1:spikeWidth,'Uni',0)),1:nclus,'Uni',0),1:nclus,'Uni',0);
    % LocDistSign = cat(1,LocDistSign{:});
    % LocDistSim = cellfun(@(X) nanmean(X),LocDistSign);

    disp('Computing location angle (direction) differences between pairs of units, per individual time point of the waveform...')
    % Difference in angle between two time points
    x1 = ProjectedLocationPerTP(:,:,2:spikeWidth,:);
    x2 = ProjectedLocationPerTP(:,:,1:spikeWidth-1,:);
    LocAngle = squeeze(atan(abs(x1(1,:,:,:)-x2(1,:,:,:))./abs(x1(2,:,:,:)-x2(2,:,:,:))));
    x1 = repmat(LocAngle(:,:,1),[1 1 nclus]);
    x2 = permute(repmat(LocAngle(:,:,2),[1 1 nclus]),[3 2 1]);
    w = ~isnan(x1+x2);
    x1(~w) = 0;
    x2(~w) = 0;
    LocAngleSim = squeeze(circ_mean(abs(x1-x2),w,2));
    % LocAngle = arrayfun(@(uid) cell2mat(arrayfun(@(tp) atan(abs(squeeze(ProjectedLocationPerTP(1,uid,tp,:)-ProjectedLocationPerTP(1,uid,tp-1,:)))./abs(squeeze(ProjectedLocationPerTP(2,uid,tp,:)-ProjectedLocationPerTP(2,uid,tp-1,:)))),2:spikeWidth,'Uni',0)),1:nclus,'Uni',0);
    % LocAngleSim = arrayfun(@(uid) cell2mat(arrayfun(@(uid2) circ_mean(abs(LocAngle{uid}(1,~isnan(LocAngle{uid}(1,:)) & ~isnan(LocAngle{uid2}(2,:)))' - LocAngle{uid2}(2,~isnan(LocAngle{uid}(1,:)) & ~isnan(LocAngle{uid2}(2,:)))')),1:nclus,'Uni',0)),1:nclus,'Uni',0);
    % LocAngleSim = cat(1,LocAngleSim{:});

    % Variance in error, corrected by average error. This captures whether
    % the trajectory is consistenly separate
    MSELoc = squeeze(nanvar(LocDistSign,[],3)./nanmean(LocDistSign,3)+nanmean(LocDistSign,3));
    % MSELoc = cell2mat(cellfun(@(X) nanvar(X)./nanmean(X)+nanmean(X),LocDistSign,'Uni',0));

    % Normalize each of them from 0 to 1, 1 being the 'best'
    % If distance > maxdist micron it will never be the same unit:
    LocDistSim = 1-((LocDistSim-nanmin(LocDistSim(:)))./(maxdist-nanmin(LocDistSim(:)))); %Average difference
    LocDistSim(LocDistSim<0)=0;
    LocDist = 1-((LocDist-nanmin(LocDist(:)))./(maxdist-nanmin(LocDist(:))));
    LocDist(LocDist<0)=0;
    MSELoc = 1-((MSELoc-nanmin(MSELoc(:)))./(nanmax(MSELoc(:))-nanmin(MSELoc(:))));
    LocAngleSim = 1-((LocAngleSim-nanmin(LocAngleSim(:)))./(nanmax(LocAngleSim(:))-nanmin(LocAngleSim(:))));

    %
    figure('name','Distance Measures')
    subplot(4,2,1)
    h=imagesc(LocDist);
    title('LocationDistance')
    xlabel('Unit_i')
    ylabel('Unit_j')
    hold on
    arrayfun(@(X) line([SessionSwitch(X) SessionSwitch(X)],get(gca,'ylim'),'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
    arrayfun(@(X) line(get(gca,'xlim'),[SessionSwitch(X) SessionSwitch(X)],'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
    colormap(flipud(gray))
    colorbar
    makepretty

    subplot(4,2,2)
    h=histogram(LocDist(:));
    xlabel('Score')
    makepretty

    subplot(4,2,3)
    h=imagesc(LocDistSim);
    title('LocationDistanceAveraged')
    xlabel('Unit_i')
    ylabel('Unit_j')
    hold on
    arrayfun(@(X) line([SessionSwitch(X) SessionSwitch(X)],get(gca,'ylim'),'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
    arrayfun(@(X) line(get(gca,'xlim'),[SessionSwitch(X) SessionSwitch(X)],'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
    colormap(flipud(gray))
    colorbar
    makepretty
    subplot(4,2,4)
    h=histogram(LocDistSim(:));
    xlabel('Score')
    makepretty

    subplot(4,2,5)
    h=imagesc(MSELoc);
    title('average trajectory error')
    xlabel('Unit_i')
    ylabel('Unit_j')
    hold on
    arrayfun(@(X) line([SessionSwitch(X) SessionSwitch(X)],get(gca,'ylim'),'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
    arrayfun(@(X) line(get(gca,'xlim'),[SessionSwitch(X) SessionSwitch(X)],'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
    colormap(flipud(gray))
    colorbar
    makepretty
    subplot(4,2,6)
    h=histogram(MSELoc(:));
    xlabel('Score')
    makepretty

    subplot(4,2,7)
    h=imagesc(LocAngleSim);
    title('circular mean Angle difference')
    xlabel('Unit_i')
    ylabel('Unit_j')
    hold on
    arrayfun(@(X) line([SessionSwitch(X) SessionSwitch(X)],get(gca,'ylim'),'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
    arrayfun(@(X) line(get(gca,'xlim'),[SessionSwitch(X) SessionSwitch(X)],'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
    colormap(flipud(gray))
    colorbar
    makepretty
    subplot(4,2,8)
    h=histogram(LocAngleSim(:));
    xlabel('Score')
    makepretty
    LocDistSim(isnan(LocDistSim))=0;
    LocationCombined = nanmean(cat(3,LocDistSim,LocAngleSim),3);
    disp(['Extracting projected location took ' num2str(round(toc(timercounter)./60)) ' minutes for ' num2str(nclus) ' units'])

    %% These are the parameters to include:
    figure('name','Total Score components');
    for sid = 1:length(Scores2Include)
        eval(['tmp = ' Scores2Include{sid} ';'])
        subplot(round(sqrt(length(Scores2Include))),ceil(sqrt(length(Scores2Include))),sid)
        h=imagesc(tmp,[quantile(tmp(:),0.1) 1]);
        title(Scores2Include{sid})
        xlabel('Unit_i')
        ylabel('Unit_j')
        hold on
        arrayfun(@(X) line([SessionSwitch(X) SessionSwitch(X)],get(gca,'ylim'),'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
        arrayfun(@(X) line(get(gca,'xlim'),[SessionSwitch(X) SessionSwitch(X)],'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
        colormap(flipud(gray))
        colorbar
        makepretty
    end

    %% Calculate total score
    priorMatch = 1-(nclus*ndays)./(nclus*nclus);
    leaveoutmatches = false(nclus,nclus,length(Scores2Include)); %Used later
    figure;
    if length(Scores2Include)>1
        for scid=1:length(Scores2Include)
            ScoresTmp = Scores2Include(scid);
            %             ScoresTmp(scid)=[];

            TotalScore = zeros(nclus,nclus);
            for scid2=1:length(ScoresTmp)
                eval(['TotalScore=TotalScore+' ScoresTmp{scid2} ';'])
            end
            base = length(ScoresTmp)-1;

            TotalScoreAcrossDays = TotalScore;
            TotalScoreAcrossDays(X==Y)=nan;

            subplot(2,length(Scores2Include),scid)
            h=imagesc(triu(TotalScore,1),[0 base+1]);
            title([Scores2Include{scid}])
            xlabel('Unit_i')
            ylabel('Unit_j')
            hold on
            arrayfun(@(X) line([SessionSwitch(X) SessionSwitch(X)],get(gca,'ylim'),'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
            arrayfun(@(X) line(get(gca,'xlim'),[SessionSwitch(X) SessionSwitch(X)],'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
            colormap(flipud(gray))
            colorbar
            makepretty

            % Thresholds
            ThrsOpt = quantile(TotalScore(:),priorMatch); %Select best ones only later
            if ThrsOpt == max(TotalScore(:))
                ThrsOpt = ThrsOpt-0.1;
            end
            subplot(2,length(Scores2Include),scid+(length(Scores2Include)))
            leaveoutmatches(:,:,scid)=TotalScore>ThrsOpt;
            imagesc(triu(TotalScore>ThrsOpt,1))
            hold on
            title(['Thresholding at ' num2str(ThrsOpt)])
            xlabel('Unit_i')
            ylabel('Unit_j')
            hold on
            arrayfun(@(X) line([SessionSwitch(X) SessionSwitch(X)],get(gca,'ylim'),'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
            arrayfun(@(X) line(get(gca,'xlim'),[SessionSwitch(X) SessionSwitch(X)],'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
            colormap(flipud(gray))
            colorbar
            %     axis square
            makepretty
        end
    end
    TotalScore = zeros(nclus,nclus);
    Predictors = zeros(nclus,nclus,0);
    for scid2=1:length(Scores2Include)
        Predictors = cat(3,Predictors,eval(Scores2Include{scid2}));

        if ~IncludeSpatialInitially & strcmp(Scores2Include{scid2},'LocDistSim')
            continue
        end
        eval(['TotalScore=TotalScore+' Scores2Include{scid2} ';'])
    end
    figure('name','TotalScore')
    subplot(2,1,1)
    h=imagesc(TotalScore,[0 length(Scores2Include)]);
    title(['Total Score'])
    xlabel('Unit_i')
    ylabel('Unit_j')
    hold on
    arrayfun(@(X) line([SessionSwitch(X) SessionSwitch(X)],get(gca,'ylim'),'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
    arrayfun(@(X) line(get(gca,'xlim'),[SessionSwitch(X) SessionSwitch(X)],'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
    colormap(flipud(gray))
    colorbar
    makepretty

    % Make initial threshold --> to be optimized
    ThrsOpt = quantile(TotalScore(:),priorMatch); %Select best ones only later
    subplot(2,1,2)
    imagesc(TotalScore>ThrsOpt)
    hold on
    title(['Thresholding at ' num2str(ThrsOpt)])
    xlabel('Unit_i')
    ylabel('Unit_j')
    hold on
    arrayfun(@(X) line([SessionSwitch(X) SessionSwitch(X)],get(gca,'ylim'),'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
    arrayfun(@(X) line(get(gca,'xlim'),[SessionSwitch(X) SessionSwitch(X)],'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
    colormap(flipud(gray))
    colorbar
    % axis square
    makepretty
    % Find all pairs
    % first factor authentication: score above threshold
    ThrsScore = ThrsOpt;
    % Take into account:
    label = TotalScore>ThrsOpt;
    [uid,uid2] = find(label);
    Pairs = cat(2,uid,uid2);
    Pairs = sortrows(Pairs);
    Pairs=unique(Pairs,'rows');
    Pairs(Pairs(:,1)==Pairs(:,2),:)=[];

    %% Functional score for optimization: compute Fingerprint for the matched units - based on Célian Bimbard's noise-correlation finger print method but applied to across session correlations
    % Not every recording day will have the same units. Therefore we will
    % correlate each unit's activity with average activity across different
    % depths
    % Use a bunch of units with high total scores as reference population
    timercounter = tic;
    disp('Computing fingerprints correlations...')
    [PairScore,sortid] = sort(cell2mat(arrayfun(@(X) TotalScore(Pairs(X,1),Pairs(X,2)),1:size(Pairs,1),'Uni',0)),'descend');
    Pairs = Pairs(sortid,:);
    CrossCorrelationFingerPrint

    figure;
    h=scatter(TotalScore(:),FingerprintR(:),14,RankScoreAll(:),'filled','AlphaData',0.1);
    colormap(cat(1,[0 0 0],winter))
    xlabel('TotalScore')
    ylabel('Cross-correlation fingerprint')
    makepretty
    disp(['Computing fingerprints correlations took ' num2str(round(toc(timercounter)./60)) ' minutes for ' num2str(nclus) ' units'])

    %% three ways to define candidate scores
    % Total score larger than threshold
    CandidatePairs = TotalScore>ThrsOpt & SigMask==1;
    %     CandidatePairs(tril(true(size(CandidatePairs))))=0;
    figure('name','Potential Matches')
    imagesc(CandidatePairs)
    colormap(flipud(gray))
    %     xlim([SessionSwitch nclus])
    %     ylim([1 SessionSwitch-1])
    xlabel('Units day 1')
    ylabel('Units day 2')
    title('Potential Matches')
    makepretty

    %% Calculate median drift on this population (between days)
    if ndays>1
        for did = 1:ndays-1
            idx = find(Pairs(:,1)>=SessionSwitch(did)&Pairs(:,1)<SessionSwitch(did+1) & Pairs(:,2)>=SessionSwitch(did+1)&Pairs(:,2)<SessionSwitch(did+2));
            drift = nanmedian(cell2mat(arrayfun(@(uid) (nanmean(ProjectedLocation(:,Pairs(idx,1),:),3)-nanmean(ProjectedLocation(:,Pairs(idx,2),:),3)),1:size(Pairs,1),'Uni',0)),2);
            disp(['Median drift recording ' num2str(did) ' calculated: X=' num2str(drift(1)) ', Y=' num2str(drift(2))])
            if flag
                break
            end
            ProjectedLocation(1,GoodRecSesID==did+1,:)=ProjectedLocation(1,GoodRecSesID==did+1,:)+drift(1);
            ProjectedLocation(2,GoodRecSesID==did+1,:)=ProjectedLocation(2,GoodRecSesID==did+1,:)+drift(2);
            ProjectedLocationPerTP(1,GoodRecSesID==did+1,:,:) = ProjectedLocationPerTP(1,GoodRecSesID==did+1,:,:) + drift(1);
            ProjectedLocationPerTP(2,GoodRecSesID==did+1,:,:) = ProjectedLocationPerTP(2,GoodRecSesID==did+1,:,:) + drift(2);
            close all

        end
    else
        break
    end
    flag = flag+1;

end
%% Prepare naive bayes - inspect probability distributions
% Prepare a set INCLUDING the cross-validated self-scores, otherwise the probability
% distributions are just weird
priorMatch = 1-(nclus*ndays)./(nclus*nclus); %Now use a slightly more lenient prior
ThrsOpt = quantile(TotalScore(:),priorMatch);
CandidatePairs = TotalScore>ThrsOpt & RankScoreAll==1 & SigMask==1;
% CandidatePairs(tril(true(size(CandidatePairs)),-1))=0;
[uid,uid2] = find(CandidatePairs);
Pairs = cat(2,uid,uid2);
Pairs = sortrows(Pairs);
Pairs=unique(Pairs,'rows');

%% Naive bayes classifier
% Usually this means there's no variance in the match distribution
% (which in a way is great). Create some small variance
flag = 0;
npairs = 0;
MinLoss=1;
MaxPerf = [0 0];
npairslatest = 0;
runid=0;
% Priors = [0.5 0.5];
Priors = [priorMatch 1-priorMatch];
BestMdl = [];
while flag<2 && runid<maxrun
    flag = 0;
    runid=runid+1
    filedir = which('UnitMatch');
    filedir = dir(filedir);
    if ApplyExistingBayesModel && exist(fullfile(filedir.folder,'UnitMatchModel.mat'))
        load(fullfile(SaveDir,'UnitMatchModel.mat'),'BestMdl')
        % Apply naive bays classifier
        Tbl = array2table(reshape(Predictors,[],size(Predictors,3)),'VariableNames',Scores2Include); %All parameters

        if isfield(BestMdl,'Parameterkernels')
            [label, posterior] = ApplyNaiveBayes(Tbl,BestMdl.Parameterkernels,[0 1],Priors);
        else
            [label, posterior, cost] = predict(BestMdl,Tbl);
        end
    else
        tmp= reshape(Predictors(Pairs(:,1),Pairs(:,2),:),[],length(Scores2Include));
        Tbl = array2table(reshape(tmp,[],size(tmp,2)),'VariableNames',Scores2Include); %All parameters
        % Use Rank as 'correct' label
        label = reshape(CandidatePairs(Pairs(:,1),Pairs(:,2)),1,[])';
        if MakeOwnNaiveBayes
            % Work in progress
            [Parameterkernels,Performance] = CreateNaiveBayes(Tbl,label,Priors);
            if any(Performance'<MaxPerf)
                flag = flag+1;
            else
                BestMdl.Parameterkernels = Parameterkernels;
            end
            % Apply naive bays classifier
            Tbl = array2table(reshape(Predictors,[],size(Predictors,3)),'VariableNames',Scores2Include); %All parameters
            [label, posterior] = ApplyNaiveBayes(Tbl,Parameterkernels,[0 1],Priors);

        else % This uses matlab package. Warning: normal distributions assumed?
            try
                Mdl = fitcnb(Tbl,label);
            catch ME
                disp(ME)
                keyboard
                for id = 1:size(Predictors,3)
                    tmp = Predictors(:,:,id);
                    if nanvar(tmp(CandidatePairs(:)==1)) == 0
                        %Add some noise
                        tmp(CandidatePairs(:)==1) = tmp(CandidatePairs(:)==1)+(rand(sum(CandidatePairs(:)==1),1)-0.5)./2;
                        tmp(tmp>1)=1;
                        Predictors(:,:,id)=tmp;
                    end
                end
            end
            % Cross validate on model that uses only prior
            DefaultPriorMdl = Mdl;
            FreqDist = cell2table(tabulate(label==1));
            DefaultPriorMdl.Prior = FreqDist{:,3};
            rng(1);%
            defaultCVMdl = crossval(DefaultPriorMdl);
            defaultLoss = kfoldLoss(defaultCVMdl);

            CVMdl = crossval(Mdl);
            Loss = kfoldLoss(CVMdl);

            if Loss>defaultLoss
                warning('Model doesn''t perform better than chance')
            end
            if round(Loss*10000) >= round(MinLoss*10000)
                flag = flag+1;
            elseif Loss<MinLoss
                MinLoss=Loss;
                BestMdl = Mdl;
            end
            disp(['Loss = ' num2str(round(Loss*10000)/10000)])

            % Apply naive bays classifier
            Tbl = array2table(reshape(Predictors,[],size(Predictors,3)),'VariableNames',Scores2Include); %All parameters
            [label, posterior, cost] = predict(Mdl,Tbl);

            %% Evaluate Model:
            figure('name','NaiveBayesEstimates')
            for parid=1:size(Predictors,3)

                subplot(size(Predictors,3),1,parid)
                mu = BestMdl.DistributionParameters{1,parid}(1);
                sigma = BestMdl.DistributionParameters{1,parid}(2);
                x = (-5 * sigma:0.01:5*sigma)+mu;
                plot(x,normpdf(x,mu,sigma),'b-')
                hold on
                mu = BestMdl.DistributionParameters{2,parid}(1);
                sigma = BestMdl.DistributionParameters{2,parid}(2);
                x = (-5 * sigma:0.01:5*sigma)+mu;
                plot(x,normpdf(x,mu,sigma),'r-')
                title(Scores2Include{parid})

                makepretty
                xlim([0 1])


            end


        end
    end
    drawnow

    if runid<maxrun % Otherwise a waste of time!
        label = reshape(label,size(Predictors,1),size(Predictors,2));
        [r, c] = find(triu(label)==1); %Find matches

        Pairs = cat(2,r,c);
        Pairs = sortrows(Pairs);
        Pairs=unique(Pairs,'rows');
        %     Pairs(Pairs(:,1)==Pairs(:,2),:)=[];
        MatchProbability = reshape(posterior(:,2),size(Predictors,1),size(Predictors,2));
        %     figure; imagesc(label)

        % Functional score for optimization: compute Fingerprint for the matched units - based on Célian Bimbard's noise-correlation finger print method but applied to across session correlations
        % Not every recording day will have the same units. Therefore we will
        % correlate each unit's activity with average activity across different
        % depths
        disp('Recalculate activity correlations')

        % Use a bunch of units with high total scores as reference population
        [PairScore,sortid] = sort(cell2mat(arrayfun(@(X) MatchProbability(Pairs(X,1),Pairs(X,2)),1:size(Pairs,1),'Uni',0)),'descend');
        Pairs = Pairs(sortid,:);
        CrossCorrelationFingerPrint

        tmpf = triu(FingerprintR,1);
        tmpm = triu(MatchProbability,1);
        tmpm = tmpm(tmpf~=0);
        tmpf = tmpf(tmpf~=0);
        tmpr = triu(RankScoreAll,1);
        tmpr = tmpr(tmpr~=0);

        figure;
        scatter(tmpm,tmpf,14,tmpr,'filled')
        colormap(cat(1,[0 0 0],winter))
        xlabel('Match Probability')
        ylabel('Cross-correlation fingerprint')
        makepretty
        drawnow

        % New Pairs for new round
        CandidatePairs = label==1 & RankScoreAll==1& SigMask==1;
        CandidatePairs(tril(true(size(CandidatePairs)),-1))=0;
        [uid,uid2] = find(CandidatePairs);
        Pairs = cat(2,uid,uid2);
        Pairs = sortrows(Pairs);
        Pairs=unique(Pairs,'rows');
    end
end

%% If this was stitched pykilosort, we know what pykilosort thought about the matches
PyKSLabel = [];
PairsPyKS = [];
if RunPyKSChronicStitched
    for uid = 1:nclus
        pairstmp = find(AllClusterIDs(Good_Idx)==AllClusterIDs(Good_Idx(uid)))';
        if length(pairstmp)>1
            PairsPyKS = cat(1,PairsPyKS,pairstmp);
        end
    end

    PyKSLabel = false(nclus,nclus);
    for pid = 1:size(PairsPyKS,1)
        PyKSLabel(PairsPyKS(pid,1),PairsPyKS(pid,2)) = true;
        PyKSLabel(PairsPyKS(pid,2),PairsPyKS(pid,1)) = true;
    end
    PyKSLabel(logical(eye(size(PyKSLabel)))) = true;
    PairsPyKS=unique(PairsPyKS,'rows');

    figure('name','Parameter Scores');
    Edges = [0:stepsize:1];
    ScoreVector = Edges(1)+stepsize/2:stepsize:Edges(end)-stepsize/2;

    for scid=1:length(Scores2Include)
        eval(['ScoresTmp = ' Scores2Include{scid} ';'])
        ScoresTmp(tril(true(size(ScoresTmp))))=nan;
        subplot(ceil(sqrt(length(Scores2Include))),round(sqrt(length(Scores2Include))),scid)
        hc = histcounts(ScoresTmp(~PyKSLabel),Edges)./sum(~PyKSLabel(:));
        plot(ScoreVector,hc,'b-')
        hold on

        hc = histcounts(ScoresTmp(PyKSLabel),Edges)./sum(PyKSLabel(:));
        plot(ScoreVector,hc,'r-')


        title(Scores2Include{scid})
        makepretty
    end
    legend('Non-matches','Matches')
end
%% Extract final pairs:
disp('Extracting final pairs of units...')
Tbl = array2table(reshape(Predictors,[],size(Predictors,3)),'VariableNames',Scores2Include); %All parameters
if isfield(BestMdl,'Parameterkernels')
    if RunPyKSChronicStitched
        [label, posterior,performance] = ApplyNaiveBayes(Tbl,BestMdl.Parameterkernels,PyKSLabel(:),Priors);
        disp(['Correctly labelled ' num2str(round(performance(2)*1000)/10) '% of PyKS Matches and ' num2str(round(performance(1)*1000)/10) '% of PyKS non matches'])

        disp('Results if training would be done with PyKs stitched')
        [ParameterkernelsPyKS,Performance] = CreateNaiveBayes(Tbl,PyKSLabel(:),Priors);
        [Fakelabel, Fakeposterior,performance] = ApplyNaiveBayes(Tbl,ParameterkernelsPyKS,PyKSLabel(:),Priors);
        disp(['Correctly labelled ' num2str(round(performance(2)*1000)/10) '% of PyKS Matches and ' num2str(round(performance(1)*1000)/10) '% of PyKS non matches'])
    else
        [label, posterior] = ApplyNaiveBayes(Tbl,BestMdl.Parameterkernels,[0 1],Priors);
    end
else
    [label, posterior, cost] = predict(BestMdl,Tbl);
end
MatchProbability = reshape(posterior(:,2),size(Predictors,1),size(Predictors,2));
label = (MatchProbability>=param.ProbabilityThreshold) | (MatchProbability>0.05 & RankScoreAll==1 & SigMask==1);
% label = reshape(label,nclus,nclus);
[r, c] = find(triu(label)==1); %Find matches across 2 days
Pairs = cat(2,r,c);
Pairs = sortrows(Pairs);
Pairs=unique(Pairs,'rows');
% Pairs(Pairs(:,1)==Pairs(:,2),:)=[];
figure; imagesc(label)
colormap(flipud(gray))
xlabel('Unit_i')
ylabel('Unit_j')
hold on
arrayfun(@(X) line([SessionSwitch(X) SessionSwitch(X)],get(gca,'ylim'),'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
arrayfun(@(X) line(get(gca,'xlim'),[SessionSwitch(X) SessionSwitch(X)],'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
title('Identified matches')
makepretty

%% Check different probabilities, what does the match graph look like?
figure;
takethisprob = [0.5 0.75 0.95 0.99];
for pid = 1:4
    subplot(2,2,pid)
    h = imagesc(MatchProbability>takethisprob(pid));
    colormap(flipud(gray))
    makepretty
    xlabel('Unit_i')
    ylabel('Unit_j')
    hold on
    arrayfun(@(X) line([SessionSwitch(X) SessionSwitch(X)],get(gca,'ylim'),'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
    arrayfun(@(X) line(get(gca,'xlim'),[SessionSwitch(X) SessionSwitch(X)],'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
    title(['p>' num2str(takethisprob(pid))])
end

%% Fingerprint correlations
disp('Recalculate activity correlations')

% Use a bunch of units with high total scores as reference population
[PairScore,sortid] = sort(cell2mat(arrayfun(@(X) MatchProbability(Pairs(X,1),Pairs(X,2)),1:size(Pairs,1),'Uni',0)),'descend');
Pairs = Pairs(sortid,:);
% CrossCorrelationFingerPrint - do we really need this again?
%%
figure;
subplot(1,3,1)
imagesc(RankScoreAll==1 & SigMask==1)
hold on
arrayfun(@(X) line([SessionSwitch(X) SessionSwitch(X)],get(gca,'ylim'),'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
arrayfun(@(X) line(get(gca,'xlim'),[SessionSwitch(X) SessionSwitch(X)],'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
colormap(flipud(gray))
title('Rankscore == 1*')
makepretty

subplot(1,3,2)
imagesc(MatchProbability>param.ProbabilityThreshold)
hold on
arrayfun(@(X) line([SessionSwitch(X) SessionSwitch(X)],get(gca,'ylim'),'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
arrayfun(@(X) line(get(gca,'xlim'),[SessionSwitch(X) SessionSwitch(X)],'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
colormap(flipud(gray))
title('Match Probability>0.5')
makepretty

subplot(1,3,3)
imagesc(MatchProbability>=param.ProbabilityThreshold | (MatchProbability>0.05 & RankScoreAll==1 & SigMask==1));

% imagesc(MatchProbability>=0.99 | (MatchProbability>=0.05 & RankScoreAll==1 & SigMask==1))
hold on
arrayfun(@(X) line([SessionSwitch(X) SessionSwitch(X)],get(gca,'ylim'),'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
arrayfun(@(X) line(get(gca,'xlim'),[SessionSwitch(X) SessionSwitch(X)],'color',[1 0 0]),2:length(SessionSwitch),'Uni',0)
colormap(flipud(gray))
title('final matches')
makepretty


tmpf = triu(FingerprintR);
tmpm = triu(MatchProbability);
tmpm = tmpm(tmpf~=0);
tmpf = tmpf(tmpf~=0);
tmpr = triu(RankScoreAll);
tmpr = tmpr(tmpr~=0);

figure;
scatter(tmpm,tmpf,14,tmpr,'filled')
colormap(cat(1,[0 0 0],winter))
xlabel('Match Probability')
ylabel('Cross-correlation fingerprint')
makepretty

%% Extract final pairs:
label = MatchProbability>=param.ProbabilityThreshold | (MatchProbability>0.05 & RankScoreAll==1 & SigMask==1);
% label = MatchProbability>=0.99 | (MatchProbability>=0.05 & RankScoreAll==1 & SigMask==1);
[r, c] = find(triu(label,1)); %Find matches
Pairs = cat(2,r,c);
Pairs = sortrows(Pairs);
Pairs=unique(Pairs,'rows');
Pairs(Pairs(:,1)==Pairs(:,2),:)=[];

if RunPyKSChronicStitched

    [Int,A,B] = intersect(Pairs,PairsPyKS,'rows');
    PercDetected = size(Int,1)./size(PairsPyKS,1).*100;
    disp(['Detected ' num2str(PercDetected) '% of PyKS matched units'])

    PercOver = (size(Pairs,1)-size(Int,1))./size(PairsPyKS,1)*100;
    disp(['Detected ' num2str(PercOver) '% more units than just PyKS matched units'])

    % interesting: Not detected
    NotB = 1:size(PairsPyKS,1);
    NotB(B) = [];
    OnlyDetectedByPyKS = PairsPyKS(NotB,:);

    % Figure out what hasn't been detected:
    % Extract individual parameter scores for these specific 'pairs'
    TmpSc = cell2mat(arrayfun(@(X) squeeze(Predictors(OnlyDetectedByPyKS(X,1),OnlyDetectedByPyKS(X,2),:)),1:size(OnlyDetectedByPyKS,1),'Uni',0));

    % p(X|Match)
    [~,minidx] = arrayfun(@(X) min(abs(X-ScoreVector)),TmpSc,'Uni',0); % Find index for observation in score vector
    minidx=cell2mat(minidx);
    % Only interested in matches:
    MatchLkh = cell2mat(arrayfun(@(Y) Parameterkernels(minidx(Y,:),Y,2),1:size(minidx,1),'Uni',0));

    figure;
    subplot(2,2,1)
    imagesc(TmpSc')
    colormap(flipud(gray))
    title('Scores')

    subplot(2,2,2)
    imagesc(MatchLkh)
    colormap(flipud(gray))
    title('likelihood_Match')

    TmpMP = cell2mat(arrayfun(@(X) squeeze(MatchProbability(OnlyDetectedByPyKS(X,1),OnlyDetectedByPyKS(X,2))),1:size(OnlyDetectedByPyKS,1),'Uni',0));

    figure('name','OnlyDetecedPyKS');
    for scid=1:length(Scores2Include)
        subplot(ceil(sqrt(length(Scores2Include))),round(sqrt(length(Scores2Include))),scid)
        histogram(TmpSc(scid,:),Edges)
        title(Scores2Include{scid})
    end

    % Too much detected
    NotA = 1:size(Pairs,1);
    NotA(A) = [];
    NotdetectedByPyKS = Pairs(NotA,:);

end


%% TotalScore Pair versus no pair
SelfScore = MatchProbability(logical(eye(size(MatchProbability))));
scorematches = nan(size(Pairs,1),1); %First being TotalScore, second being TemplateMatch
scoreNoMatches = MatchProbability;
scoreNoMatches(logical(eye(size(MatchProbability))))=nan;

for id = 1:size(Pairs,1)
    scorematches(id,1) = MatchProbability(Pairs(id,1),Pairs(id,2));
    scoreNoMatches(Pairs(id,1),Pairs(id,2),:)=nan;
    scoreNoMatches(Pairs(id,2),Pairs(id,1),:)=nan;
end
ThrsScore = min(MatchProbability(label==1));
figure;
subplot(1,2,1)
histogram(scoreNoMatches(:),[0:0.01:1]); hold on
title('Non Matches')
xlabel('Match Probability')
ylabel('Nr Pairs')
makepretty
subplot(1,2,2)
histogram(SelfScore(:),[0:0.01:1]); hold on
histogram(scorematches(:),[0:0.01:1]);
line([ThrsScore ThrsScore],get(gca,'ylim'),'color',[1 0 0])

% histogram(scorematches(:,1),[0:0.02:6])
xlabel('Matching Probability')
ylabel('Nr Pairs')
legend('Self Score','Matches','Threshold','Location','best')
makepretty

save(fullfile(SaveDir,'MatchingScores.mat'),'BestMdl','SessionSwitch','GoodRecSesID','AllClusterIDs','Good_Idx','WavformSim','WVCorr','LocationCombined','waveformTimePointSim','PeakTimeSim','spatialdecaySim','TotalScore','label','MatchProbability')
save(fullfile(SaveDir,'UnitMatchModel.mat'),'BestMdl')
%% inspect probability distributions
figure('name','Parameter Scores');
Edges = [0:0.01:1];
for scid=1:length(Scores2Include)
    eval(['ScoresTmp = ' Scores2Include{scid} ';'])
    ScoresTmp(tril(true(size(ScoresTmp))))=nan;
    subplot(length(Scores2Include),2,(scid-1)*2+1)
    histogram(ScoresTmp(~label),Edges)
    if scid==1
        title('Identified non-Matches')
    end
    ylabel(Scores2Include{scid})
    makepretty

    subplot(length(Scores2Include),2,scid*2)
    histogram(ScoresTmp(label),Edges)
    if scid==1
        title('Identified Matches')
    end
    makepretty
end

%
figure('name','Projected Location Distance to [0 0]')
Dist2Tip = sqrt(nansum(ProjectedLocation.^2,1));
% Dist2TipMatrix = nan(size(CandidatePairs));

Dist2TipMatrix = arrayfun(@(Y) cell2mat(arrayfun(@(X) cat(1,Dist2Tip(X),Dist2Tip(Y)),1:nclus,'Uni',0)),1:nclus,'Uni',0);
Dist2TipMatrix = cat(3,Dist2TipMatrix{:});
Dist2TipMatrix = reshape(Dist2TipMatrix,2,[]);
subplot(1,2,1)
[N,C] = hist3(Dist2TipMatrix(:,~label(:))');
imagesc(N)
colormap(flipud(gray))
makepretty
xlabel('Unit_i')
ylabel('Unit_j')
zlabel('Counts')
title('Identified Non-matches')

subplot(1,2,2)
[N,C] = hist3(Dist2TipMatrix(:,label(:))');
imagesc(N)
colormap(flipud(gray))
makepretty
xlabel('Unit_i')
ylabel('Unit_j')
zlabel('Counts')
title('Identified Matches')

% Waveform duration
figure('name','WaveDur')
waveformdurationMat = arrayfun(@(Y) cell2mat(arrayfun(@(X) cat(1,waveformduration(X),waveformduration(Y)),1:nclus,'UniformOutput',0)),1:nclus,'UniformOutput',0);
waveformdurationMat = cat(3,waveformdurationMat{:});
subplot(1,2,1)
[N,C] = hist3(waveformdurationMat(:,~label(:))');
imagesc(N)
colormap(flipud(gray))
makepretty
xlabel('Unit_i')
ylabel('Unit 2')
zlabel('Counts')
title('Identified Non-matches')

subplot(1,2,2)
[N,C] = hist3(waveformdurationMat(:,label(:))');
imagesc(N)
colormap(flipud(gray))
makepretty
xlabel('Unit_i')
ylabel('Unit_j')
zlabel('Counts')
title('Identified Matches')

% SpatialDecaySlope
figure('name','Spatial Decay Slope')
SpatDecMat = arrayfun(@(Y) cell2mat(arrayfun(@(X) cat(1,spatialdecay(X),spatialdecay(Y)),1:nclus,'UniformOutput',0)),1:nclus,'UniformOutput',0);
SpatDecMat = cat(3,SpatDecMat{:});
subplot(1,2,1)
[N,C] = hist3(SpatDecMat(:,~label(:))');
imagesc(N)
colormap(flipud(gray))
makepretty
xlabel('Unit_i')
ylabel('Unit_j')
zlabel('Counts')
title('Identified Non-matches')

subplot(1,2,2)
[N,C] = hist3(SpatDecMat(:,label(:))');
imagesc(N)
colormap(flipud(gray))
makepretty
xlabel('Unit_i')
ylabel('Unit_j')
zlabel('Counts')
title('Identified Matches')
%% ISI violations (for over splits matching)
ISIViolationsScore = nan(1,size(Pairs,1));
fprintf(1,'Computing functional properties similarity. Progress: %3d%%',0)
for pairid= 1:size(Pairs,1)
    if GoodRecSesID(Pairs(pairid,1)) == GoodRecSesID(Pairs(pairid,2))
        idx1 = sp.spikeTemplates == AllClusterIDs(Good_Idx(Pairs(pairid,1)))&sp.RecSes == GoodRecSesID(Pairs(pairid,1));
        idx2 = sp.spikeTemplates == AllClusterIDs(Good_Idx(Pairs(pairid,2)))&sp.RecSes == GoodRecSesID(Pairs(pairid,2));
        DifScore = diff(sort([sp.st(idx1); sp.st(idx2)]));
        ISIViolationsScore(pairid) = sum(DifScore.*1000<1.5)./length(DifScore);
        fprintf(1,'\b\b\b\b%3.0f%%',pairid/size(Pairs,1)*100)

    end
end
fprintf('\n')
disp(['Removing ' num2str(sum(ISIViolationsScore>0.05)) ' matched oversplits, as merging them will violate ISI >5% of the time'])
Pairs(ISIViolationsScore>0.05,:)=[];


%% Average in 3rd dimension (halfs of a session)
ProjectedWaveform = nanmean(ProjectedWaveform,3); %Average over first and second half of session
ProjectedLocation = nanmean(ProjectedLocation,3);
ProjectedLocationPerTP = nanmean(ProjectedLocationPerTP,4);

%% Figures
if MakePlotsOfPairs
    if ~isdir(fullfile(SaveDir,'MatchFigures'))
        mkdir(fullfile(SaveDir,'MatchFigures'))
    else
        delete(fullfile(SaveDir,'MatchFigures','*'))
    end
    if size(Pairs,1)>drawmax
        DrawPairs = randsample(1:size(Pairs,1),drawmax,'false');
    else
        DrawPairs = 1:size(Pairs,1);
    end
    % Pairs = Pairs(any(ismember(Pairs,[8,68,47,106]),2),:);
    %     AllClusterIDs(Good_Idx(Pairs))
    for pairid=DrawPairs
        uid = Pairs(pairid,1);
        uid2 = Pairs(pairid,2);

         pathparts = strsplit(AllDecompPaths{GoodRecSesID(uid)},'\');
        rawdatapath = dir(fullfile('\\',pathparts{1:end-1}));
        if isempty(rawdatapath)
            rawdatapath = dir(fullfile(pathparts{1:end-1}));
        end

        % Load raw data
        SM1=load(fullfile(SaveDir,'UnitMatchWaveforms',['Unit' num2str(UniqueID(Good_Idx(uid))) '_RawSpikes.mat']));
        SM1 = SM1.spikeMap; %Average across these channels

        pathparts = strsplit(AllDecompPaths{GoodRecSesID(uid2)},'\');
        rawdatapath = dir(fullfile('\\',pathparts{1:end-1}));
        if isempty(rawdatapath)
            rawdatapath = dir(fullfile(pathparts{1:end-1}));
        end

        SM2=load(fullfile(SaveDir,'UnitMatchWaveforms',['Unit' num2str(UniqueID(Good_Idx(uid2))) '_RawSpikes.mat']));
        SM2 = SM2.spikeMap; %Average across these channels

        tmpfig = figure;
        subplot(3,3,[1,4])
        ChanIdx = find(cell2mat(arrayfun(@(Y) norm(channelpos(MaxChannel(uid,cv),:)-channelpos(Y,:)),1:size(channelpos,1),'UniformOutput',0))<TakeChannelRadius); %Averaging over 10 channels helps with drift
        Locs = channelpos(ChanIdx,:);
        for id = 1:length(Locs)
            plot(Locs(id,1)*5+[1:size(SM1,1)],Locs(id,2)*10+nanmean(SM1(:,ChanIdx(id),:),3),'b-','LineWidth',1)
            hold on
        end
        plot(ProjectedLocation(1,uid)*5+[1:size(SM1,1)],ProjectedLocation(2,uid)*10+ProjectedWaveform(:,uid),'b--','LineWidth',2)

        ChanIdx = find(cell2mat(arrayfun(@(Y) norm(channelpos(MaxChannel(uid2,cv),:)-channelpos(Y,:)),1:size(channelpos,1),'UniformOutput',0))<TakeChannelRadius); %Averaging over 10 channels helps with drift
        Locs = channelpos(ChanIdx,:);
        for id = 1:length(Locs)
            plot(Locs(id,1)*5+[1:size(SM2,1)],Locs(id,2)*10+nanmean(SM2(:,ChanIdx(id),:),3),'r-','LineWidth',1)
            hold on
        end
        plot(ProjectedLocation(1,uid2)*5+[1:size(SM1,1)],ProjectedLocation(2,uid2)*10+ProjectedWaveform(:,uid2),'r--','LineWidth',2)

        makepretty
        set(gca,'xticklabel',arrayfun(@(X) num2str(X./5),cellfun(@(X) str2num(X),get(gca,'xticklabel')),'UniformOutput',0))
        set(gca,'yticklabel',arrayfun(@(X) num2str(X./10),cellfun(@(X) str2num(X),get(gca,'yticklabel')),'UniformOutput',0))
        xlabel('Xpos (um)')
        ylabel('Ypos (um)')
        title(['unit' num2str(AllClusterIDs(Good_Idx(uid))) ' versus unit' num2str(AllClusterIDs(Good_Idx(uid2))) ', ' 'RecordingDay ' num2str(GoodRecSesID(uid)) ' versus ' num2str(GoodRecSesID(uid2)) ', Probability=' num2str(round(MatchProbability(uid,uid2).*100)) '%'])

        subplot(3,3,[2])

        hold on
        takesamples = WaveIdx(uid,:,:);
        takesamples = unique(takesamples(~isnan(takesamples)));
        h(1) = plot(squeeze(ProjectedLocationPerTP(1,uid,takesamples)),squeeze(ProjectedLocationPerTP(2,uid,takesamples)),'b-');
        scatter(squeeze(ProjectedLocationPerTP(1,uid,takesamples)),squeeze(ProjectedLocationPerTP(2,uid,takesamples)),30,takesamples,'filled')
        colormap(hot)

        takesamples = WaveIdx(uid2,:,:);
        takesamples = unique(takesamples(~isnan(takesamples)));

        h(2) = plot(squeeze(ProjectedLocationPerTP(1,uid2,takesamples)),squeeze(ProjectedLocationPerTP(2,uid2,takesamples)),'r-');
        scatter(squeeze(ProjectedLocationPerTP(1,uid2,takesamples)),squeeze(ProjectedLocationPerTP(2,uid2,takesamples)),30,takesamples,'filled')
        colormap(hot)
        xlabel('Xpos (um)')
        ylabel('Ypos (um)')
        ydif = diff(get(gca,'ylim'));
        xdif = diff(get(gca,'xlim'));
        stretch = (ydif-xdif)./2;
        set(gca,'xlim',[min(get(gca,'xlim')) - stretch, max(get(gca,'xlim')) + stretch])
        %     legend([h(1),h(2)],{['Unit ' num2str(uid)],['Unit ' num2str(uid2)]})
        hc= colorbar;
        hc.Label.String = 'timesample';
        makepretty
        title(['Distance: ' num2str(round(LocDistSim(uid,uid2)*100)./100) ', angle: ' num2str(round(LocAngleSim(uid,uid2)*100)./100)])

        subplot(3,3,5)
        plot(channelpos(:,1),channelpos(:,2),'k.')
        hold on
        h(1)=plot(channelpos(MaxChannel(uid),1),channelpos(MaxChannel(uid),2),'b.','MarkerSize',15);
        h(2) = plot(channelpos(MaxChannel(uid2),1),channelpos(MaxChannel(uid2),2),'r.','MarkerSize',15);
        xlabel('X position')
        ylabel('um from tip')
        makepretty
        title(['Chan ' num2str(MaxChannel(uid)) ' versus ' num2str(MaxChannel(uid2))])

        subplot(3,3,3)
        hold on
        SM1 = squeeze(nanmean(SM1(:,MaxChannel(uid),:),2));
        SM2 = squeeze(nanmean(SM2(:,MaxChannel(uid2),:),2));
        h(1)=plot(nanmean(SM1(:,1:2:end),2),'b-');
        h(2)=plot(nanmean(SM1(:,2:2:end),2),'b--');
        h(3)=plot(nanmean(SM2(:,1:2:end),2),'r-');
        h(4)=plot(nanmean(SM2(:,2:2:end),2),'r--');
        makepretty
        title(['Waveform Similarity=' num2str(round(WavformSim(uid,uid2)*100)./100) ', WVCorr=' num2str(round(WVCorr(uid,uid2)*100)./100) ', Ampl=' ...
            num2str(round(AmplitudeSim(uid,uid2)*100)./100) ', decay='  num2str(round(spatialdecaySim(uid,uid2)*100)./100)])


        % Scatter spikes of each unit
        subplot(3,3,6)
        idx1=find(sp.spikeTemplates == AllClusterIDs(Good_Idx(uid)) & sp.RecSes == GoodRecSesID(uid));
        scatter(sp.st(idx1)./60,sp.spikeAmps(idx1),4,[0 0 1],'filled')
        hold on
        idx2=find(sp.spikeTemplates == AllClusterIDs(Good_Idx(uid2)) &  sp.RecSes == GoodRecSesID(uid2));
        scatter(sp.st(idx2)./60,-sp.spikeAmps(idx2),4,[1 0 0],'filled')
        xlabel('Time (min)')
        ylabel('Abs(Amplitude)')
        title(['Amplitude distribution'])
        xlims = get(gca,'xlim');
        ylims = max(abs(get(gca,'ylim')));
        % Other axis
        [h1,edges,binsz]=histcounts(sp.spikeAmps(idx1));
        %Normalize between 0 and 1
        h1 = ((h1-nanmin(h1))./(nanmax(h1)-nanmin(h1)))*10+xlims(2)+10;
        plot(h1,edges(1:end-1),'b-');
        [h2,edges,binsz]=histcounts(sp.spikeAmps(idx2));
        %Normalize between 0 and 1
        h2 = ((h2-nanmin(h2))./(nanmax(h2)-nanmin(h2)))*10+xlims(2)+10;
        plot(h2,-edges(1:end-1),'r-');
        ylabel('Amplitude')
        ylim([-ylims ylims])

        makepretty


        % compute ACG
        [ccg, ~] = CCGBz([double(sp.st(idx1)); double(sp.st(idx1))], [ones(size(sp.st(idx1), 1), 1); ...
            ones(size(sp.st(idx1), 1), 1) * 2], 'binSize', param.ACGbinSize, 'duration', param.ACGduration, 'norm', 'rate'); %function
        ACG = ccg(:, 1, 1);
        [ccg, ~] = CCGBz([double(sp.st(idx2)); double(sp.st(idx2))], [ones(size(sp.st(idx2), 1), 1); ...
            ones(size(sp.st(idx2), 1), 1) * 2], 'binSize', param.ACGbinSize, 'duration', param.ACGduration, 'norm', 'rate'); %function
        ACG2 = ccg(:, 1, 1);
        [ccg, ~] = CCGBz([double(sp.st([idx1;idx2])); double(sp.st([idx1;idx2]))], [ones(size(sp.st([idx1;idx2]), 1), 1); ...
            ones(size(sp.st([idx1;idx2]), 1), 1) * 2], 'binSize', param.ACGbinSize, 'duration', param.ACGduration, 'norm', 'rate'); %function

        subplot(3,3,7); plot(ACG,'b');
        hold on
        plot(ACG2,'r')
        title(['AutoCorrelogram'])
        makepretty
        subplot(3,3,8)

        if exist('NatImgCorr','var')
            if GoodRecSesID(uid)==1 % Recording day 1
                tmp1 = squeeze(D0(OriginalClusID(Good_Idx(uid))+1,:,:));
            else % Recordingday 2
                tmp1 = squeeze(D1(OriginalClusID(Good_Idx(uid))+1,:,:));
            end
            if GoodRecSesID(uid2)==1 % Recording day 1
                tmp2 = squeeze(D0(OriginalClusID(Good_Idx(uid2))+1,:,:));
            else % Recordingday 2
                tmp2 = squeeze(D1(OriginalClusID(Good_Idx(uid2))+1,:,:));
            end

            plot(nanmean(tmp1,1),'b-');
            hold on
            plot(nanmean(tmp2,1),'r-');
            xlabel('Stimulus')
            ylabel('NrSpks')
            makepretty


            if AllClusterIDs(Good_Idx(uid))  == AllClusterIDs(Good_Idx(uid2))
                if ismember(Good_Idx(uid),Good_ClusUnTracked)
                    title(['Visual: Untracked, r=' num2str(round(NatImgCorr(pairid,pairid)*100)/100)])
                elseif ismember(Good_Idx(uid),Good_ClusTracked)
                    title(['Visual: Tracked, r=' num2str(round(NatImgCorr(pairid,pairid)*100)/100)])
                else
                    title(['Visual: Unknown, r=' num2str(round(NatImgCorr(pairid,pairid)*100)/100)])
                end
            else
                title(['Visual: Unknown, r=' num2str(round(NatImgCorr(pairid,pairid)*100)/100)])
            end
        else
            isitot = diff(sort([sp.st(idx1); sp.st(idx2)]));
            histogram(isitot,'FaceColor',[0 0 0])
            hold on
            line([1.5/1000 1.5/1000],get(gca,'ylim'),'color',[1 0 0],'LineStyle','--')
            title([num2str(round(sum(isitot*1000<1.5)./length(isitot)*1000)/10) '% ISI violations']); %The higher the worse (subtract this percentage from the Total score)
            xlabel('ISI (ms)')
            ylabel('Nr. Spikes')
            makepretty
        end

        subplot(3,3,9)
       
        SessionCorrelations = AllSessionCorrelations{recsesGood(uid),recsesGood(uid2)};
        addthis3=-SessionSwitch(recsesGood(uid))+1;
        if recsesGood(uid2)>recsesGood(uid)
            addthis4=-SessionSwitch(recsesGood(uid2))+1+ncellsperrecording(recsesGood(uid));
        else
            addthis4=-SessionSwitch(recsesGood(uid2))+1;
        end
        plot(SessionCorrelations(uid+addthis3,:),'b-'); hold on; plot(SessionCorrelations(uid2+addthis4,:),'r-')
        hold off
        xlabel('Unit')
        ylabel('Cross-correlation')
        title(['Fingerprint r=' num2str(round(FingerprintR(uid,uid2)*100)/100) ', rank=' num2str(RankScoreAll(uid,uid2))])
        ylims = get(gca,'ylim');
        set(gca,'ylim',[ylims(1) ylims(2)*1.2])
        PosMain = get(gca,'Position');
        makepretty

        axes('Position',[PosMain(1)+(PosMain(3)*0.8) PosMain(2)+(PosMain(4)*0.8) PosMain(3)*0.2 PosMain(4)*0.2])
        box on
        tmp1 = FingerprintR(uid,:);
        tmp1(uid2)=nan;
        tmp2 = FingerprintR(:,uid2);
        tmp2(uid)=nan;
        tmp = cat(2,tmp1,tmp2');
        histogram(tmp,'EdgeColor','none','FaceColor',[0.5 0.5 0.5])
        hold on
        line([FingerprintR(uid,uid2) FingerprintR(uid,uid2)],get(gca,'ylim'),'color',[1 0 0])
        xlabel('Finger print r')
        makepretty
        %
        %         disp(['UniqueID ' num2str(AllClusterIDs(Good_Idx(uid))) ' vs ' num2str(AllClusterIDs(Good_Idx(uid2)))])
        %         disp(['Peakchan ' num2str(MaxChannel(uid)) ' versus ' num2str(MaxChannel(uid2))])
        %         disp(['RecordingDay ' num2str(GoodRecSesID(uid)) ' versus ' num2str(GoodRecSesID(uid2))])

        drawnow
        set(gcf,'units','normalized','outerposition',[0 0 1 1])
       
        saveas(gcf,fullfile(SaveDir,'MatchFigures',[num2str(round(MatchProbability(uid,uid2).*100)) 'ClusID' num2str(AllClusterIDs(Good_Idx(uid))) 'vs' num2str(AllClusterIDs(Good_Idx(uid2))) '.fig']))
        saveas(gcf,fullfile(SaveDir,'MatchFigures',[num2str(round(MatchProbability(uid,uid2).*100)) 'ClusID' num2str(AllClusterIDs(Good_Idx(uid))) 'vs' num2str(AllClusterIDs(Good_Idx(uid2))) '.bmp']))

        close(tmpfig)
    end
end

%% Assign same Unique ID
[PairID1,PairID2]=meshgrid(AllClusterIDs(Good_Idx));
[recses1,recses2] = meshgrid(recsesAll(Good_Idx));
MatchTable = table(PairID1(:),PairID2(:),recses1(:),recses2(:),MatchProbability(:),RankScoreAll(:),FingerprintR(:),'VariableNames',{'ID1','ID2','RecSes1','RecSes2','MatchProb','RankScore','FingerprintCor'})
for id = 1:size(Pairs,1)
    UniqueID(Good_Idx(Pairs(id,2))) = UniqueID(Good_Idx(Pairs(id,1)));
end

if RemoveRawWavForms && exist(fullfile(SaveDir,'UnitMatchWaveforms',['Unit' num2str(UniqueID(Good_Idx(1))) '_RawSpikes.mat']))
    delete(fullfile(SaveDir,'UnitMatchWaveforms','*')) % Free up space on servers
end
%% Unused bits and pieces
if 0
    % look for natural images data
    % AL data from Kush:
    D0 = readNPY('H:\Anna_TMP\image_analysis\responses\day_0\template_responses.npy');
    D1 = readNPY('H:\Anna_TMP\image_analysis\responses\day_1\template_responses.npy');
    % matrix: number of spikes from 0 to 0.7seconds after stimulus onset: n_templates X n_reps X n_Images
    % Get rid of the units not currently looked at (We have only shank 0 here)
    D0(1:end-length(unique(AllClusterIDs)),:,:)=[];
    D1(1:end-length(unique(AllClusterIDs)),:,:)=[];
    NatImgCorr = nan(nclus,nclus);
    nrep = size(D0,2);
    for uid=1:nclus
        uid
        if GoodRecSesID(uid)==1 % Recording day 1
            tmp1 = squeeze(D0(OriginalClusID(Good_Idx(uid))+1,:,:));
        else % Recordingday 2
            tmp1 = squeeze(D1(OriginalClusID(Good_Idx(uid))+1,:,:));
        end
        parfor uid2 = uid:nclus
            if GoodRecSesID(uid2)==1 % Recording day 1
                tmp2 = squeeze(D0(OriginalClusID(Good_Idx(uid2))+1,:,:));
            else % Recordingday 2
                tmp2 = squeeze(D1(OriginalClusID(Good_Idx(uid2))+1,:,:));
            end
            %
            %         figure; subplot(2,2,1); imagesc(tmp1); title(['Day ' num2str(GoodRecSesID(uid)) ', Unit ' num2str(OriginalClusID(Good_Idx(uid)))])
            %         colormap gray
            %         colorbar; xlabel('Condition'); ylabel('Repeat')
            %         hold on; subplot(2,2,2); imagesc(tmp2); title(['Day ' num2str(GoodRecSesID(uid2)) ', Unit ' num2str(OriginalClusID(Good_Idx(uid2)))])
            %         colormap gray
            %         colorbar; xlabel('Condition'); ylabel('Repeat')
            %         subplot(2,2,3); hold on

            % Is the unit's response predictable?
            tmpcor = nan(1,nrep);
            for cv = 1:nrep
                % define training and test
                trainidx = circshift(1:nrep,-(cv-1));
                testidx = trainidx(1);
                trainidx(1)=[];

                % Define response:
                train = nanmean(tmp1(trainidx,:),1);
                test = tmp2(testidx,:);

                % Between error
                tmpcor(1,cv) = corr(test',train');
                %             scatter(train,test,'filled')

                %             plot(train);

            end
            NatImgCorr(uid,uid2) = nanmean(nanmean(tmpcor,2));

            %         xlabel('train')
            %         ylabel('test')
            %         title(['Average Correlation ' num2str(round(NatImgCorr(uid,uid2)*100)/100)])
            %        lims = max(cat(1,get(gca,'xlim'),get(gca,'ylim')),[],1);
            %         set(gca,'xlim',lims,'ylim',lims)
            %         makepretty

        end
    end
    % Mirror these
    for uid2 = 1:nclus
        for uid=uid2+1:nclus
            NatImgCorr(uid,uid2)=NatImgCorr(uid2,uid);
        end
    end
    NatImgCorr = arrayfun(@(Y) arrayfun(@(X) NatImgCorr(Pairs(X,1),Pairs(Y,2)),1:size(Pairs,1),'UniformOutput',0),1:size(Pairs,1),'UniformOutput',0)
    NatImgCorr = cell2mat(cat(1,NatImgCorr{:}));

    % Kush's verdict:
    Good_ClusTracked = readNPY('H:\Anna_TMP\image_analysis\cluster_ids\good_clusters_tracked.npy'); % this is an index, 0 indexed so plus 1
    Good_ClusUnTracked = readNPY('H:\Anna_TMP\image_analysis\cluster_ids\good_clusters_untracked.npy') % this is an index, 0 indexed so plus 1

    Good_ClusTracked(Good_ClusTracked>max(AllClusterIDs))=[]; %
    Good_ClusUnTracked(Good_ClusUnTracked>max(AllClusterIDs)) = [];

    NotIncluded = [];
    TSGoodGr = nan(1,length(Good_ClusTracked));
    for uid = 1:length(Good_ClusTracked)
        idx = find(AllClusterIDs(Good_Idx) == Good_ClusTracked(uid));
        if length(idx)==2
            TSGoodGr(uid) = TotalScore(idx(1),idx(2));
        else
            NotIncluded = [NotIncluded  Good_ClusTracked(uid)];
        end
    end
    TSBadGr = nan(1,length(Good_ClusUnTracked));
    for uid = 1:length(Good_ClusUnTracked)
        idx = find(AllClusterIDs(Good_Idx) == Good_ClusUnTracked(uid));
        if length(idx)==2
            TSBadGr(uid) = TotalScore(idx(1),idx(2));
        else
            NotIncluded = [NotIncluded  Good_ClusUnTracked(uid)];
        end
    end
    figure; histogram(TSBadGr,[5:0.05:6]); hold on; histogram(TSGoodGr,[5:0.05:6])
    xlabel('Total Score')
    ylabel('Nr. Matches')
    legend({'Not tracked','Tracked'})
    makepretty
    %Tracked?
    Tracked = zeros(nclus,nclus);
    for uid=1:nclus
        parfor uid2 = 1:nclus
            if uid==uid2
                Tracked(uid,uid2)=0;
            elseif AllClusterIDs(Good_Idx(uid))  == AllClusterIDs(Good_Idx(uid2))
                if ismember(Good_Idx(uid),Good_ClusUnTracked) ||  ismember(Good_Idx(uid2),Good_ClusUnTracked)
                    Tracked(uid,uid2)=-1;
                elseif ismember(Good_Idx(uid),Good_ClusTracked)||  ismember(Good_Idx(uid2),Good_ClusTracked)
                    Tracked(uid,uid2)=1;
                else
                    Tracked(uid,uid2) = 0.5;
                end
            end
        end
    end
end

%% Cross-correlation
if 0
    MaxCorrelation = nan(nclus,nclus);
    EstTimeshift = nan(nclus,nclus);
    EstDrift = nan(nclus,nclus,2);

    % Create grid-space in time and space domain
    MultiDimMatrix = [];
    [SpaceMat,TimeMat] = meshgrid(cat(2,-[size(MultiDimMatrix,2)-1:-1:0],1:size(MultiDimMatrix,2)-1),cat(2,-[spikeWidth-1:-1:0],[1:spikeWidth-1]));
    for uid = 1:nclus
        parfor uid2 = 1:nclus
            tmp1 = MultiDimMatrix(:,:,uid,1);
            tmp2 = MultiDimMatrix(:,:,uid2,2);
            %Convert nan to 0
            tmp1(isnan(tmp1))=0;
            tmp2(isnan(tmp2))=0;

            %         2D cross correlation
            c = xcorr2(tmp1,tmp2);

            % Find maximum correlation
            [MaxCorrelation(uid,uid2),indx] = max(c(:));

            % Index in time domain
            EstTimeshift(uid,uid2)=TimeMat(indx); % Time shift index
            EstDrift(uid,uid2)=SpaceMat(indx);

            % Shift tmp2 by those pixels/time points
            tmp2 = circshift(tmp2,EstTimeshift(uid,uid2),1);
            tmp2 = circshift(tmp2,EstDrift(uid,uid2),2);

            MaxCorrelation(uid,uid2) = corr(tmp1(tmp1(:)~=0&tmp2(:)~=0),tmp2(tmp1(:)~=0&tmp2(:)~=0));

        end
    end
end
