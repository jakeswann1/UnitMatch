function AllWVBParameters = ExtractParameters(Path4UnitNPY,clusinfo,param)

%% Extract relevant information
nclus = length(Path4UnitNPY);
spikeWidth = param.spikeWidth;
Allchannelpos = param.channelpos;
waveidx = param.waveidx;
NewPeakLoc = param.NewPeakLoc;

recsesAll = clusinfo.RecSesID;
if param.GoodUnitsOnly
    Good_Idx = find(clusinfo.Good_ID); %Only care about good units at this point
else
    Good_Idx = 1:length(clusinfo.Good_ID);
    disp('Use all units including MUA and noise')

end
recsesGood = recsesAll(Good_Idx);

%% Initialize
ProjectedLocation = nan(2,nclus,2);
ProjectedLocationPerTP = nan(2,nclus,spikeWidth,2);
ProjectedWaveform = nan(spikeWidth,nclus,2); % Just take waveform on maximal channel
PeakTime = nan(nclus,2); % Peak time first versus second half
MaxChannel = nan(nclus,2); % Max channel first versus second half
waveformduration = nan(nclus,2); % Waveformduration first versus second half
Amplitude = nan(nclus,2); % Maximum (weighted) amplitude, first versus second half
spatialdecay = nan(nclus,2); % how fast does the unit decay across space, first versus second half
WaveIdx = false(nclus,spikeWidth,2);
A0Distance = nan(nclus,2); % Distance at which amplitudes are 0
expFun = @(p,d) p(2)*(1-exp(-p(1)*d)); % for spatial decay
expFun2 = @(p,d) p(1)*exp(-p(2)*d); % For SNR Decay
opts = optimset('Display','off');

%% Take geographically close channels (within 50 microns!), not just index!
timercounter = tic;
fprintf(1,'Extracting waveform information. Progress: %3d%%',0)
for uid = 1:nclus
    fprintf(1,'\b\b\b\b%3.0f%%',uid/nclus*100)
    % load data
    spikeMap = readNPY(Path4UnitNPY{uid});

    % Detrending
    spikeMap = permute(spikeMap,[2,1,3]); %detrend works over columns
    spikeMap = detrend(spikeMap,1); % Detrend (linearly) to be on the safe side. OVER TIME!
    spikeMap = permute(spikeMap,[2,1,3]);  % Put back in order

    try
        channelpos = Allchannelpos{recsesGood(uid)};
    catch ME
        % assume they all have the same configuration
        channelpos = Allchannelpos{recsesGood(uid)-1};
    end

    % Extract channel positions that are relevant and extract mean location
    [~,MaxChanneltmp] = nanmax(nanmax(abs(nanmean(spikeMap(35:70,:,:),3)),[],1));
    OriChanIdx = find(cell2mat(arrayfun(@(Y) norm(channelpos(MaxChanneltmp,:)-channelpos(Y,:)),1:size(channelpos,1),'UniformOutput',0))<param.TakeChannelRadius); %Averaging over 10 channels helps with drift
    OriLocs = channelpos(OriChanIdx,:);

    % Extract unit parameters -
    % Cross-validate: first versus second half of session
    for cv = 1:2
        ChanIdx = OriChanIdx;
        Locs = OriLocs;
        % Find maximum channels:
        [~,MaxChannel(uid,cv)] = nanmax(nanmax(abs(spikeMap(35:70,ChanIdx,cv)),[],1)); %Only over relevant channels, in case there's other spikes happening elsewhere simultaneously
        MaxChannel(uid,cv) = ChanIdx(MaxChannel(uid,cv));


        %     % Mean waveform - first extract the 'weight' for each channel, based on
        %     % how close they are to the projected location (closer = better)
        Distance2MaxChan = sqrt(nansum(abs(Locs-channelpos(MaxChannel(uid,cv),:)).^2,2));

        % Determine distance at which it's just noise
        SNR = (nanmean(abs(spikeMap(waveidx,ChanIdx,cv)),1)./nanstd((spikeMap(1:20,ChanIdx,cv)),[],1));
        p = lsqcurvefit(expFun2,[1 1],Distance2MaxChan',SNR,[],[],opts);
        tmpmin = 2*(log(2)/p(2));
        if tmpmin>param.TakeChannelRadius || tmpmin<0
            tmpmin = param.TakeChannelRadius;
        end

%                 figure; scatter(Distance2MaxChan',SNR); hold on
%                     plot(sort(Distance2MaxChan)',expFun2(p,sort(Distance2MaxChan)'))
%         %
        %
        %         tmpmin = max(Distance2MaxChan(SNR>3 & nanmax(abs(spikeMap(waveidx,ChanIdx,cv)),[],1)>20));
        %
        %         if isempty(tmpmin)
        %             if ~any(~isnan(SNR))
        %                 tmpmin = nan;
        %             else
        %                 tmpmin = max(Distance2MaxChan);
        %             end
        %         end

        A0Distance(uid,cv) = tmpmin;
        ChanIdx = find(cell2mat(arrayfun(@(Y) norm(channelpos(MaxChanneltmp,:)-channelpos(Y,:)),1:size(channelpos,1),'UniformOutput',0))< A0Distance(uid,cv)); %Averaging over 10 channels helps with drift
        Locs = channelpos(ChanIdx,:);
        % Mean location:
        mu = sum(repmat(nanmax(abs(spikeMap(:,ChanIdx,cv)),[],1),size(Locs,2),1).*Locs',2)./sum(repmat(nanmax(abs(spikeMap(:,ChanIdx,cv)),[],1),size(Locs,2),1),2);
        ProjectedLocation(:,uid,cv) = mu;
        % Use this waveform - weighted average across channels:
        Distance2MaxProj = sqrt(nansum(abs(Locs-ProjectedLocation(:,uid,cv)').^2,2));
        weight = (A0Distance(uid,cv)-Distance2MaxProj)./A0Distance(uid,cv);
        ProjectedWaveform(:,uid,cv) = nansum(spikeMap(:,ChanIdx,cv).*repmat(weight,1,size(spikeMap,1))',2)./sum(weight);
        % Find significant timepoints
        wvdurtmp = find(abs(ProjectedWaveform(:,uid,cv) - nanmean(ProjectedWaveform(1:20,uid,cv)))>2.5*nanstd(ProjectedWaveform(1:20,uid,cv))); % More than 2. std from baseline
        if isempty(wvdurtmp)
            wvdurtmp = waveidx;
        end
        wvdurtmp(~ismember(wvdurtmp,waveidx)) = []; %okay over achiever, gonna cut you off there
        if isempty(wvdurtmp)
            % May again be empty
            wvdurtmp = waveidx;
        end

        % Peak Time - to be safe take a bit of smoothing
        [~,PeakTime(uid,cv)] = nanmax(abs(smooth(ProjectedWaveform(wvdurtmp(1):wvdurtmp(end),uid,cv),2)));
        PeakTime(uid,cv) = PeakTime(uid,cv)+wvdurtmp(1)-1;
    end
    % Give each unit the best opportunity to correlate the waveform; cross
    % correlate to find the difference in peak
    [tmpcor, lags] = xcorr(ProjectedWaveform(:,uid,1),ProjectedWaveform(:,uid,2));
    [~,maxid] = max(tmpcor);
 
    % Shift accordingly
    ProjectedWaveform(:,uid,2) = circshift(ProjectedWaveform(:,uid,2),lags(maxid));
    spikeMap(:,:,2) = circshift(spikeMap(:,:,2),lags(maxid),1);
    if lags(maxid)>0
        ProjectedWaveform(1:lags(maxid),uid,2) = nan;
        spikeMap(1:lags(maxid),:,2) = nan;
    elseif lags(maxid)<0
        ProjectedWaveform(spikeWidth+lags(maxid):spikeWidth,uid,2) = nan;
        spikeMap(spikeWidth+lags(maxid):spikeWidth,:,2) = nan;
    end
    for cv = 1:2
        ChanIdx = OriChanIdx;
        Locs = channelpos(ChanIdx,:);
        % Shift data so that peak is at timepoint x
        if PeakTime(uid,1)~=NewPeakLoc % Yes, take the 1st CV on purpose!
            ProjectedWaveform(:,uid,cv) = circshift(ProjectedWaveform(:,uid,cv),-(PeakTime(uid,1)-NewPeakLoc));
            spikeMap(:,:,cv) = circshift(spikeMap(:,:,cv),-(PeakTime(uid,1)-NewPeakLoc),1);
            if PeakTime(uid,1)-NewPeakLoc<0
                ProjectedWaveform(1:-(PeakTime(uid,1)-NewPeakLoc),uid,cv) = nan;
                spikeMap(1:-(PeakTime(uid,1)-NewPeakLoc),:,cv) = nan;
            else
                ProjectedWaveform(spikeWidth-(PeakTime(uid,cv)-NewPeakLoc):spikeWidth,uid,cv) = nan;
                spikeMap(spikeWidth-(PeakTime(uid,1)-NewPeakLoc):spikeWidth,:,cv) = nan;
            end
        end

        %     % Mean waveform - first extract the 'weight' for each channel, based on
        %     % how close they are to the projected location (closer = better)
        Distance2MaxChan = sqrt(nansum(abs(Locs-channelpos(MaxChannel(uid,cv),:)).^2,2));

        % Difference in amplitude from maximum amplitude
        spdctmp = (abs(spikeMap(NewPeakLoc,MaxChannel(uid,cv),cv))-abs(spikeMap(NewPeakLoc,ChanIdx,cv)))./abs(spikeMap(NewPeakLoc,MaxChannel(uid,cv),cv));
        % Remove zero
        spdctmp(Distance2MaxChan==0) = [];
        Distance2MaxChan(Distance2MaxChan==0) = [];

        try
            p = lsqcurvefit(expFun,[1 1],Distance2MaxChan',spdctmp,[],[],opts);
        catch
            keyboard
        end

        spatialdecay(uid,cv) = p(1); % 
        Peakval = ProjectedWaveform(NewPeakLoc,uid,cv);
        Amplitude(uid,cv) = Peakval;

        ChanIdx = find(cell2mat(arrayfun(@(Y) norm(channelpos(MaxChanneltmp,:)-channelpos(Y,:)),1:size(channelpos,1),'UniformOutput',0))< A0Distance(uid,cv)); %Averaging over 10 channels helps with drift
        Locs = channelpos(ChanIdx,:);
        % Full width half maximum
        wvdurtmp = find(abs(sign(Peakval)*ProjectedWaveform(waveidx,uid,cv))>0.25*sign(Peakval)*Peakval);
        if ~isempty(wvdurtmp)
            wvdurtmp = [wvdurtmp(1):wvdurtmp(end)]+waveidx(1)-1;
            waveformduration(uid,cv) = length(wvdurtmp);
        else
            waveformduration(uid,cv) = nan;
        end

        % Mean Location per individual time point:
        ProjectedLocationPerTP(:,uid,wvdurtmp,cv) = cell2mat(arrayfun(@(tp) sum(repmat(abs(spikeMap(tp,ChanIdx,cv)),size(Locs,2),1).*Locs',2)./sum(repmat(abs(spikeMap(tp,ChanIdx,cv)),size(Locs,2),1),2),wvdurtmp,'Uni',0));
        WaveIdx(uid,wvdurtmp,cv) = 1;
        % Save spikes for these channels
        %         MultiDimMatrix(wvdurtmp,1:length(ChanIdx),uid,cv) = nanmean(spikeMap(wvdurtmp,ChanIdx,wavidx),3);

    end
    if  norm(channelpos(MaxChannel(uid,1),:)-channelpos(MaxChannel(uid,2),:))>param.TakeChannelRadius
        % keyboard
    end
end
fprintf('\n')
disp(['Extracting raw waveforms and parameters took ' num2str(toc(timercounter)) ' seconds for ' num2str(nclus) ' units'])
if nanmedian(A0Distance(:))>0.5*param.TakeChannelRadius
    disp('Warning, consider larger channel radius')
    keyboard
end
%% Put in struct
AllWVBParameters.ProjectedLocation = ProjectedLocation;
AllWVBParameters.ProjectedLocationPerTP = ProjectedLocationPerTP;
AllWVBParameters.ProjectedWaveform = ProjectedWaveform;
AllWVBParameters.PeakTime = PeakTime;
AllWVBParameters.MaxChannel = MaxChannel;
AllWVBParameters.waveformduration = waveformduration;
AllWVBParameters.Amplitude = Amplitude;
AllWVBParameters.spatialdecay = spatialdecay;
AllWVBParameters.WaveIdx = WaveIdx;

return
% Images for example neuron
if 0 
    uid = [10] % Example (AL032, take 10)
     fprintf(1,'\b\b\b\b%3.0f%%',uid/nclus*100)
    % load data
    spikeMap = readNPY(Path4UnitNPY{uid});

    % Detrending
    spikeMap = permute(spikeMap,[2,1,3]); %detrend works over columns
    spikeMap = detrend(spikeMap,1); % Detrend (linearly) to be on the safe side. OVER TIME!
    spikeMap = permute(spikeMap,[2,1,3]);  % Put back in order

    try
        channelpos = Allchannelpos{recsesGood(uid)};
    catch ME
        % assume they all have the same configuration
        channelpos = Allchannelpos{recsesGood(uid)-1};
    end

    % Extract channel positions that are relevant and extract mean location
    [~,MaxChanneltmp] = nanmax(nanmax(abs(nanmean(spikeMap(35:70,:,:),3)),[],1));
    ChanIdx = find(cell2mat(arrayfun(@(Y) norm(channelpos(MaxChanneltmp,:)-channelpos(Y,:)),1:size(channelpos,1),'UniformOutput',0))<param.TakeChannelRadius*3); %Averaging over 10 channels helps with drift
    Locs = channelpos(ChanIdx,:);

    % Plot
    tmp = nanmean(spikeMap(:,ChanIdx(channelpos(ChanIdx,1)==250),:),3);
    timevec = [-(param.NewPeakLoc-(1:size(spikeMap,1)))].*(1/30000)*1000; % In MS
    lims = [-20 20];
    figure; 
    subplot(2,3,1)
    imagesc(timevec,channelpos(ChanIdx(channelpos(ChanIdx,1)==0),2),tmp',lims)
    colormap redblue
    makepretty
    xlabel('Time (ms)')
    ylabel('depth (\mum)')
    title('sites at 0um')
    set(gca,'ydir','normal')
  
    subplot(2,3,2) % Peak profile
    tmp = nanmean(spikeMap(param.NewPeakLoc,ChanIdx(channelpos(ChanIdx,1)==0),:),3);
    plot(tmp,channelpos(ChanIdx(channelpos(ChanIdx,1)==0),2),'k-')
    xlabel('\muV at peak')
    ylabel('depth (\mum)')
    makepretty

    subplot(2,3,3) % average waveform
    tmp = nanmean(spikeMap(:,MaxChannel(uid,1),:),3);
    plot(timevec,tmp,'k-')
    xlabel('Time (ms)')
    ylabel('\muV at peak channel')
    makepretty


    tmp = nanmean(spikeMap(:,ChanIdx(channelpos(ChanIdx,1)==32),:),3);

    subplot(2,3,4)
    imagesc(timevec,channelpos(ChanIdx(channelpos(ChanIdx,1)==32),2),tmp',lims)
    xlabel('Time (ms)')
    ylabel('Depth (\mum)')
    title('Sites at 32um')
    set(gca,'ydir','normal')
    colormap redblue

    makepretty
    subplot(2,3,5) % Peak profile
    tmp = nanmean(spikeMap(param.NewPeakLoc,ChanIdx(channelpos(ChanIdx,1)==32),:),3);
    plot(tmp,channelpos(ChanIdx(channelpos(ChanIdx,1)==0),2),'k-')
    xlabel('\muV at peak')
    ylabel('Depth (\mum)')
    makepretty

    subplot(2,3,6) % average waveform
    tmp = nanmean(spikeMap(:,MaxChannel(uid,1),:),3);
    plot(timevec,tmp,'k-')
    xlabel('Time (ms)')
    ylabel('\muV at peak channel')
    makepretty



    % Spatial decay plot
    figure('name','Spatial Decay Plot')
    ChanIdx = find(cell2mat(arrayfun(@(Y) norm(channelpos(MaxChanneltmp,:)-channelpos(Y,:)),1:size(channelpos,1),'UniformOutput',0))<param.TakeChannelRadius); %Averaging over 10 channels helps with drift
    Locs = channelpos(ChanIdx,:);
    Distance2MaxChan = sqrt(nansum(abs(Locs-channelpos(MaxChannel(uid,cv),:)).^2,2));
    Distance2MaxChan(Distance2MaxChan==0) = [];
    % Difference in amplitude from maximum amplitude
    spdctmp = (nanmax(abs(spikeMap(:,MaxChannel(uid,cv),cv)),[],1)-nanmax(abs(spikeMap(:,ChanIdx,cv)),[],1))./nanmax(abs(spikeMap(:,MaxChannel(uid,cv),cv)),[],1);
        spdctmp(spdctmp==0) = [];

    % Spatial decay (average oer micron)
    subplot(1,4,[1:3])
    scatter(Distance2MaxChan,spdctmp,20,[0 0 0],'filled')
    xlabel('\DeltaS_x_,_y')
    ylabel('(a_s_i*-a_s)/a_s_i*')
    hold on
    for chid = 1:length(spdctmp./Distance2MaxChan')
        plot([0 Distance2MaxChan(chid)],[0 spdctmp(chid)],'k--')
    end
    nanmean(spdctmp./Distance2MaxChan')

    subplot(1,4,4)
    hold on
    for chid = 1:length(spdctmp./Distance2MaxChan')
    scatter(1,spdctmp(chid)./Distance2MaxChan(chid),20,[ 0 0 0
        ],'filled')
    end
    hold on
    scatter(1,nanmean(spdctmp./Distance2MaxChan'),50,[0 0 1],'filled')






%     p = lsqcurvefit(expFun,[1 1],Distance2MaxChan',spdctmp,[],[],opts)
%     hold on
%     plot(sort(Distance2MaxChan)',expFun(p,sort(Distance2MaxChan)'))
%     Error1 = nansum((expFun(p,sort(Distance2MaxChan)') - spdctmp).^2);
%     p = polyfit(Distance2MaxChan',spdctmp,1)
%     hold on
%     plot(sort(Distance2MaxChan)',polyval(p,sort(Distance2MaxChan)'))
%     Error2 = nansum(polyval(p,sort(Distance2MaxChan)' - spdctmp).^2);

end
