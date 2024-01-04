import numpy as np
import matplotlib.pyplot as plt
import scipy as sp
import Param_fun as pf
#from sklearn.metrics import roc_auc_score

def re_scale(vector):
    """
    This function does 0-99 rescaling to get good scores.
    """
    score = ( np.nanquantile(vector,0.99) - vector) / (np.nanquantile(vector,0.99) - np.nanmin(vector))
    score[score<0] = 0

    #score[np.isnan(score)] = 0 I would like to do but not in ML
    return score

def get_simple_metric(wave_param, outlier = False):
    """
    This function is suitable for, spatial decay, spatial decay fit, amplitude and other (no_units,2) parameters,
    where one wants to make the weighted difference the metric (CAN CHANGE THIS IF WANTED e.g if diff + True do this else do this.. )
    use if outlier = True to apply extra filtering of extreme values
    """
    n_units = wave_param.shape[0]
    x1 = np.broadcast_to(wave_param[:,0], (n_units, n_units)).T
    x2 = np.broadcast_to(wave_param[:,1], (n_units, n_units))

    # takes the difference weighted by the mean of the value of the two cross-validation halves,
    diff = np.abs(x1 - x2) / np.nanmean(np.abs( np.stack((x1,x2), axis = -1)), axis = 2)

    if outlier == True: 
        diff[diff<0] = np.nanquantile(diff, 0.9999) 
        # i think above should be diff[ diff < np.nanquantile(diff,0.0001)] = np.nanquantile(diff, 0.0001) 
        diff[ diff > np.nanquantile(diff,0.9999)] = np.nanquantile(diff, 0.9999)
        # #Below i have made it slightly less extreme, as may be difference in quantile functions
        # diff[diff<0] = np.nanquantile(diff, 0.99) 
        # # i think above should be diff[ diff < np.nanquantile(diff,0.001)] = np.nanquantile(diff, 0.001) 
        # diff[ diff > np.nanquantile(diff,0.99)] = np.nanquantile(diff, 0.99)

    sqrt_diff = np.sqrt(diff) 
    metric = re_scale(sqrt_diff)

    return metric

def get_WVcorr(Avg_waveform, param):
    """
    Calculates the correlation between weighted average wavefunction, and rescales it into a score 
    """
    waveidx = param['waveidx']
    n_units = param['n_units']

    x1 = Avg_waveform[waveidx,:,0].T 
    x2 = Avg_waveform[waveidx,:,1].T

    #calculate the correlation
    WVcorr_tmp = np.corrcoef(x1,x2)
    WVcorr = WVcorr_tmp[:n_units,n_units:]


    WVcorr = np.arctanh(WVcorr) # apply Fisher z transformation
    #make into a score
    WVcorr = (WVcorr - np.nanquantile(WVcorr,0.005)) / (np.nanquantile(WVcorr,0.995) - np.nanquantile(WVcorr, 0.005))
    WVcorr[np.isnan(WVcorr)] = 0
    WVcorr[WVcorr<0] = 0
    WVcorr[WVcorr>1] = 1 

    return WVcorr

def get_WaveFormMSE(Avg_waveform, param):
    """
    Calculates the waveform mean square error, and rescales it into a score
    """
    waveidx = param['waveidx']
    ProjectedWaveFormnorm = Avg_waveform[waveidx,:,:]
    ProjectedWaveFormnorm =  (ProjectedWaveFormnorm - np.nanmin(ProjectedWaveFormnorm,axis = 0)) / (np.nanmax(ProjectedWaveFormnorm, axis=0) - np.nanmin(ProjectedWaveFormnorm, axis = 0))

    x1 = np.tile(np.expand_dims(ProjectedWaveFormnorm[:,:,0], axis = 2), (1,1,ProjectedWaveFormnorm.shape[1]))
    x2 = np.swapaxes(np.tile(np.expand_dims(ProjectedWaveFormnorm[:,:,1], axis = 2), (1,1,ProjectedWaveFormnorm.shape[1])), 1,2 )
    RawWVMSE = np.nanmean( (x1 - x2)**2, axis = 0 ).squeeze()
    RawWVMSENorm = np.sqrt(RawWVMSE)

    WaveformMSE = re_scale(RawWVMSENorm)
    return WaveformMSE

def flip_dim(WAW_PerTP, param):
    """
    Creates a version of the weighted average wavefunction per time point, where the x axis is flipped, due to the effect
    where the average position tends to wards the center of the x coords when the wave is decaying
    """
    n_units = param['n_units']

    FlipDim = np.array((1,)) # BE CAREFUL HERE, Which dimension is the x-axis  
    WAW_PerTP_flip = np.full((3, n_units,82,2, len(FlipDim)+1), np.nan)

    for i in range(len(FlipDim)):
        tmpdat = WAW_PerTP[FlipDim[i]  ,:,:,:]

        newvals = np.nanmin(tmpdat, axis =1, keepdims=True) + np.nanmax(tmpdat, axis = 1, keepdims=True) - tmpdat
        WAW_PerTP_flip[:,:,:,:,i] = WAW_PerTP
        WAW_PerTP_flip[FlipDim[i],:,:,:,i] = newvals

    WAW_PerTP_flip[:,:,:,:,-1] = WAW_PerTP

    return WAW_PerTP_flip

def get_Euclidean_dist(WAW_PerTP_flip,param):
    """
    Calculated the Euclidean distance between the units at each time point and for the flipped axis case
    """
    # Euclidean distance between WAW_PerTP_ML_flip, between the 2 CV

    # This can get to LARGE arrays 3*566*82*2*2*566 ~ Billions...
    #if this is slow dask may be a good idea..
    # all function have dask version so *should be simple to use dask* 

    waveidx = param['waveidx']
    n_units = param['n_units']

    x1 = np.tile( np.expand_dims(WAW_PerTP_flip[:,:,waveidx,0,:], axis = -1), (1,1,1,1,n_units)).squeeze()
    x2 = np.swapaxes(np.tile( np.expand_dims(WAW_PerTP_flip[:,:,waveidx,1,:], axis = -1), (1,1,1,1,n_units)).squeeze(), 1, 4)

    w = np.isnan( np.abs(x1[0,:,:,:,:] - x2[0,:,:,:,:])).squeeze()

    tmpEu = np.linalg.norm(x1-x2, axis = 0)
    tmpEu[w] = np.nan
    EuclDist = tmpEu
    del x1
    del x2
    del w
    del tmpEu
    return EuclDist

def Centroid_metrics(EuclDist, param):
    """
    This function calculates the score for the centroid distance and centroid variance.
    """
    MaxDist = param['MaxDist']
    waveidx = param['waveidx']
    NewPeakLoc = param['PeakLoc']    

    CentroidDist = np.nanmin( EuclDist[:,NewPeakLoc - waveidx ==0,:,:].squeeze(), axis =1 ).squeeze()


    CentroidDist = 1 - ((CentroidDist - np.nanmin(CentroidDist)) / (MaxDist - np.nanmin(CentroidDist)))
    CentroidDist[CentroidDist<0] = 0
    CentroidDist[np.isnan(CentroidDist)] = 0

    #Centroid Var
    # need ddof = 1 to match with ML
    CentroidVar = np.nanmin( np.nanvar(EuclDist, axis = 1, ddof = 1 ).squeeze(), axis =1 ).squeeze()
    CentroidVar = np.sqrt(CentroidVar)
    CentroidVar = re_scale(CentroidVar)
    CentroidVar[np.isnan(CentroidVar)] = 0

    return CentroidDist, CentroidVar

def get_recentered_Euclidean_dist(WAW_PerTP_flip, AvgCentroid, param):
    """
    Find a Euclidean distance where the location per time has been centered around the average position
    """

    waveidx = param['waveidx']
    n_units = param['n_units']

    # Recented projectlocation , aka subtract the avg location, the we can unique info
    Avg_centroid_broadcast = np.tile(np.expand_dims(AvgCentroid, axis= (3,4)), (1,1,1,82,2))
    WAW_PerTP_ML_flip_Recnt = np.swapaxes( np.swapaxes(WAW_PerTP_flip, 2,3) - Avg_centroid_broadcast,2,3)
    x1 = np.tile( np.expand_dims(WAW_PerTP_ML_flip_Recnt[:,:,waveidx,0,:], axis = -1), (1,1,1,1,n_units)).squeeze()
    x2 = np.swapaxes(np.tile( np.expand_dims(WAW_PerTP_ML_flip_Recnt[:,:,waveidx,1,:], axis = -1), (1,1,1,1,n_units)).squeeze(), 1, 4)

    w = np.isnan( np.abs(x1[0,:,:,:,:] - x2[0,:,:,:,:])).squeeze()

    tmpEu = np.linalg.norm(x1-x2, axis = 0)
    tmpEu[w] = np.nan
    EuclDist_2 = tmpEu
    del x1
    del x2
    del w
    del tmpEu
    return EuclDist_2

def recentered_metrics(EuclDist_2, param = None):
    """
    Calculates the euclidean distance between units when the centroid has been recentered
    """

    CentroidDistRecentered = np.nanmin( np.nanmean(EuclDist_2, axis =1), axis =1)
    CentroidDistRecentered = re_scale(CentroidDistRecentered)
    CentroidDistRecentered[np.isnan(CentroidDistRecentered)] = 0
    return CentroidDistRecentered

def dist_angle(WAW_PerTP_flip, param):
    """
    This function uses the weighted average location per time point, to find metric based of off:
    The distance traveled by the unit at each time point
    The angle at each time point 
    """
    waveidx = param['waveidx']
    n_units = param['n_units']
    MinAngleDist = param['MinAngleDist']
    
    #Distance between time steps and angle
    x1 = WAW_PerTP_flip[:,:,waveidx[1]:waveidx[-1] +1,:,:]
    x2 = WAW_PerTP_flip[:,:,waveidx[0]:waveidx[-2] +1,:,:] # Difference between python and ML indexing



    TrajDist = np.linalg.norm(x1-x2, axis= 0)

    LocAngle = np.full(np.append(TrajDist.shape, 3), np.nan)
    #only select points which have enough movement to get a angle
    good_ang = np.zeros_like(TrajDist)
    good_ang[TrajDist>=MinAngleDist] = 1

    countid = 0
    for dimid1 in range(WAW_PerTP_flip.shape[0]):
        for dimid2 in np.arange(1,WAW_PerTP_flip.shape[0]):
            if dimid2 <= dimid1:
                continue
            ang = np.abs( x1[dimid1,:,:,:,:] - x2[dimid1,:,:,:,:]) / np.abs(x1[dimid2,:,:,:,:] - x2[dimid2,:,:,:,:])
            
            LocAngle[:,:,:,:,countid] = np.arctan(ang) * good_ang # only selects angles for units where there is sufficient distance between time poitns
            countid +=1


    LocAngle = np.nansum(LocAngle, axis=4)
    x1 = np.tile (np.expand_dims(LocAngle[:,:,0,:], axis = -1), (1,1,1,n_units))
    x2 = np.swapaxes(np.tile(np.expand_dims(LocAngle[:,:,1,:], axis = -1), (1,1,1,n_units)), 0,3)


    AngleSubtraction = np.abs(x1-x2)
    AngleSubtraction[np.isnan(np.abs(x1 - x2))] = 2 * np.pi # make nan values punished 

    TrajAngleSim = np.nanmin( np.nansum(AngleSubtraction, axis=1), axis = 1)
    TrajAngleSim = re_scale(TrajAngleSim)
    TrajAngleSim[np.isnan(TrajAngleSim)] = 0

    x1 = np.tile (np.expand_dims(TrajDist[:,:,0,:], axis = -1), (1,1,1,n_units))
    x2 = np.swapaxes(np.tile(np.expand_dims(TrajDist[:,:,1,:], axis = -1), (1,1,1,n_units)), 0,3)

    TrajDistComapred = np.abs(x1-x2)

    TrajDistSim = np.nanmin( np.nansum(TrajDistComapred , axis = 1), axis= 1)
    TrajDistSim = np.sqrt(TrajDistSim)
    TrajDistSim = re_scale(TrajDistSim)
    TrajDistSim[np.isnan(TrajDistSim)] = 0

    return TrajAngleSim, TrajDistSim


def get_threshold(TotalScore, WithinSession, EuclDist, param, is_first_pass = True):
    """
    Uses the TotalScore, Euclidean distance,to determine a threshold for putative matches.

    If it is the first pass through the data i.e no drift correction has been done, we would expect the
    Total score for the matches to be smaller than expected, therefore we calculate the difference in mean
    for within and and between session to lower the threshold
    """
    # take between session out
    ScoreVector = param['ScoreVector']
    Bins = param['Bins']

    tmp = TotalScore.copy()
    tmp[EuclDist > param['NeighbourDist'] ] = np.nan

    tmp[WithinSession == 1] = np.nan

    hd, __ = np.histogram(np.diag(tmp), Bins)
    hd = hd /  param['n_units']
    hnd, __ = np.histogram( (tmp - tmp *np.eye(param['n_units'])), Bins)
    hnd = hnd / np.nansum( (tmp - tmp *np.eye(param['n_units'])) )
    hp, __ = np.histogram(tmp, Bins)
    hp = hp / np.nansum(tmp)

    ThrsOpt = ScoreVector[np.argwhere( (pf.smooth(hd,3) > pf.smooth(hnd,3) ) * (ScoreVector > 0.6) == True)][0]
    # if ThrsOpt.size == 0:
    #     ThrsOpt = 0.6 # give default threshold if above doestn return value
    # fit tmp to a normal ditn
    fit = tmp[ ~np.isnan(tmp) * (tmp < ThrsOpt)]
    muw = np.mean(fit)
    stdw = np.std(fit)

    if param['n_days'] > 1:
        if is_first_pass == True:
            # take within session out

            tmp = TotalScore.copy()
            tmp[EuclDist > param['NeighbourDist'] ] = np.nan

            tmp[WithinSession == 0] = np.nan

            ha, __ = np.histogram(tmp, Bins)
            ha = ha / np.nansum(tmp)
            fit = tmp[ ~np.isnan(tmp) * (tmp < ThrsOpt)]
            mua = np.mean(fit)
            stda = np.std(fit)


            # for first pass only (i.e before drift correction)
            #This is to decrease the threshold for the first pass so that the threshold is lowered
            # as without drift correction even matches should have a lower total score
            if (~np.isnan(mua) and mua<muw):
                ThrsOpt = ThrsOpt - np.abs(muw - mua)

    return ThrsOpt

def get_good_matches(pairs, TotalScore):
    """
    This function takes in a list of potential matches (n, 2) and return a list of matches where each unit can only appear once.
    This mean one unit will not be mathced to multiple units providing a better estimate at the cost of loosing some units.
    The "best" match is decided by the match which has the highest total score.
    """
    # Need to make sure the first and second unit in the matchesonly appears once
    for PairID in range(2):

        idx, count = np.unique(pairs[:,PairID], return_counts= True)
        ls = np.argwhere(count != 1)
        tmp_vals = idx[ls] # returns the unit idx for PairID, where there is more than one potential match

        #Go through each case where there is more than 1 match
        for i in range(len(tmp_vals)):
            # find the unit idx pair, e.g if unit 2 matches with unit 272 and 278 this will find (2,272) then (2,278)
            tmp_pair = np.argwhere(pairs[:,PairID] == tmp_vals[i]) # idx of pair for the multiple mathced unit
            tmp = pairs[tmp_pair,:].squeeze() # unit idx pair, for each double match e.g (2,272) and (2,278)

            scores = np.zeros(len(tmp))
            for z in range(len(tmp)):
                scores[z] = TotalScore[tmp[z,0], tmp[z,1]] #Get their score

            BestMatch = np.argmax(scores)
            #set the worse matches to -1
            for z in range(len(tmp)):
                if z != BestMatch:
                    # cannot remove yet, as it will change all of the found indices, so set the value to -1, the at the end can remove all apperaances of -1
                    pairs[tmp_pair[z], :] = np.full_like(pairs[tmp_pair[z], :], -1)
    
    good_pairs = np.delete(pairs, np.argwhere(pairs[:,0] == -1), axis = 0)

    return good_pairs
   

def drift_correction_basic(CandidatePairs, SessionSwitch, AvgCentroid, WeightedAvgWaveF_PerTP):
    """
    Uses the median difference in position, between putative matches to gain a value of drift between sessions 
    This is then applied to the AvgCentroid and the WeightedAvgWaveF_PerTP
    """
    #Drift.. currently only doing drift correction between 2 days/sessions
    BestPairs = np.argwhere(CandidatePairs == 1)

    # #Just to make it like the matlab code, as in matlab the axes are swapped
    BestPairs[:, [0,1]] = BestPairs[:, [1,0]]
    idx = np.argwhere( ((BestPairs[:,0] < SessionSwitch[1]) * (BestPairs[:,1] >= SessionSwitch[1])) == True)

    drift = np.nanmedian( np.nanmean( AvgCentroid[:, BestPairs[idx,0].squeeze(),:], axis = 2) - np.nanmean( AvgCentroid[:,BestPairs[idx,1].squeeze(),:], axis = 2), axis = 1)


    ##need to add the drift to the location on each of these, and the flipped if I decide to not recalulate it
    WeightedAvgWaveF_PerTP[0,SessionSwitch[1]:,:,:] += drift[0]
    WeightedAvgWaveF_PerTP[1,SessionSwitch[1]:,:,:] += drift[1]
    WeightedAvgWaveF_PerTP[2,SessionSwitch[1]:,:,:] += drift[2]

    AvgCentroid[0,SessionSwitch[1]:,:] += drift[0]
    AvgCentroid[1,SessionSwitch[1]:,:] += drift[1]
    AvgCentroid[2,SessionSwitch[1]:,:] += drift[2]

    return drift, AvgCentroid, WeightedAvgWaveF_PerTP

def apply_drift_corection_basic(Pairs, did, SessionSwitch, AvgCentroid, WeightedAvgWaveF_PerTP):
    """
    This function applies the basic style drift correction to a pair of sessions, as part of a n_daydrift correction  
    """

    drift = np.nanmedian( np.nanmean( AvgCentroid[:, Pairs[:,0],:], axis = 2) - np.nanmean( AvgCentroid[:,Pairs[:,1],:], axis = 2), axis = 1)


    ##need to add the drift to the location on each of these, and the flipped if I decide to not recalulate it
    WeightedAvgWaveF_PerTP[0,SessionSwitch[did+1]:SessionSwitch[did+2],:,:] += drift[0]
    WeightedAvgWaveF_PerTP[1,SessionSwitch[did+1]:SessionSwitch[did+2],:,:] += drift[1]
    WeightedAvgWaveF_PerTP[2,SessionSwitch[did+1]:SessionSwitch[did]+2,:,:] += drift[2]

    AvgCentroid[0,SessionSwitch[did+1]:SessionSwitch[did+2],:] += drift[0]
    AvgCentroid[1,SessionSwitch[did+1]:SessionSwitch[did+2],:] += drift[1]
    AvgCentroid[2,SessionSwitch[did+1]:SessionSwitch[did+2],:] += drift[2]

    return drift, WeightedAvgWaveF_PerTP, AvgCentroid

def appply_drift_correction_per_shank(Pairs, did, SessionSwitch, AvgCentroid, WeightedAvgWaveF_PerTP, param):
    """
    This is the same as "basic" drift correction, however treats each shank seperatley 
    """
    ShankID = shank_ID_per_session(AvgCentroid ,SessionSwitch ,did , param)
    No_shanks = param['NoShanks']
    Shank_dist = param['ShankDist']

    
    CentroidA = np.nanmean( AvgCentroid[:,Pairs[:,0],:], axis = 2)
    CentroidB = np.nanmean( AvgCentroid[:,Pairs[:,1],:], axis = 2)

    max_dist = 0
    min_dist = 0
    drift_per_shank = np.zeros([4,3])

    for i in range(No_shanks):
        max_dist += Shank_dist

        #test to see if a centroid is within the area of that shank
        a_idx = np.logical_and(CentroidA[1,:] < max_dist,  CentroidA[1,:] > min_dist)
        b_idx = np.logical_and(CentroidB[1,:] < max_dist,  CentroidB[1,:] > min_dist)

        if np.all(a_idx == b_idx) != True:
            print(f'These pairs may be bad {np.argwhere(a_idx != b_idx)}')

        drifts = CentroidA[:,a_idx] - CentroidB[:,b_idx]
        drift =  np.nanmedian(drifts, axis = 1)
        drift_per_shank[i,:] = drift

        #need to get idx for each shank, to apply correct drift correction

        shank_session_idx = SessionSwitch[did] + np.argwhere( ShankID == i) 

        WeightedAvgWaveF_PerTP[0,shank_session_idx,:,:] += drift[0]
        WeightedAvgWaveF_PerTP[1,shank_session_idx,:,:] += drift[1]
        WeightedAvgWaveF_PerTP[2,shank_session_idx,:,:] += drift[2]

        AvgCentroid[0,shank_session_idx,:] += drift[0]
        AvgCentroid[1,shank_session_idx,:] += drift[1]
        AvgCentroid[2,shank_session_idx,:] += drift[2]

        min_dist += Shank_dist

    return drift_per_shank, WeightedAvgWaveF_PerTP, AvgCentroid

def shank_ID_per_session(AvgCentroid ,SessionSwitch ,did , param):
    """
    This function use the average centroid, to assign each unit in a session to a shank
    """

    No_shanks = param['NoShanks']
    Shank_dist = param['ShankDist']
    max_dist = 0
    min_dist = 0

    #loadcentroid position for 1 recording session
    CentroidPos = np.nanmean( AvgCentroid[:, SessionSwitch[did]:SessionSwitch[did + 1],:], axis = 2)
    ShankID = np.zeros(CentroidPos.shape[1])

    for i in range(No_shanks):
        max_dist += Shank_dist
        #Test to see if the centroid position is in the region of the i'th shank
        a_idx = np.logical_and(CentroidPos[1,:] < max_dist,  CentroidPos[1,:] > min_dist)
        ShankID[a_idx] = i
        min_dist += Shank_dist
       
    return ShankID

def test_matches_per_shank(Pairs, AvgCentroid, did, param):
    """
    Checks to see how many matches there are per shank, and returns false if there are less than MatchNumthreshold for one shank
    """

    DoPerShankCorrection = True

    a_pos = np.nanmean( AvgCentroid[:,Pairs[:,0],:], axis = 2)
    b_pos = np.nanmean( AvgCentroid[:,Pairs[:,1],:], axis = 2)
    ShankID_tmp = np.zeros(a_pos.shape[1])

    MatchNumThreshold = param['MatchNumThreshold']

    max_dist = 0
    min_dist = 0
    No_shanks = param['NoShanks']
    Shank_dist = param['ShankDist']

    for i in range(No_shanks):
        max_dist += Shank_dist

        a_idx = np.logical_and(a_pos[1,:] < max_dist,  a_pos[1,:] > min_dist)
        b_idx = np.logical_and(b_pos[1,:] < max_dist,  b_pos[1,:] > min_dist)

        if np.all(a_idx == b_idx) != True:
            print(f'These pairs may be bad {np.argwhere(a_idx != b_idx)}')
            
        ShankID_tmp[a_idx] = i

        min_dist += Shank_dist

    __, counts = np.unique(ShankID_tmp, return_counts=True)

    if np.any(counts < MatchNumThreshold):
        DoPerShankCorrection = False
        print(f'Session pair {did+1}/{did+2} has {counts} matches per shank, which is below threshold to do per shank drift correction')

    return DoPerShankCorrection


def drift_n_days(CandidatePairs, SessionSwitch, AvgCentroid, WeightedAvgWaveF_PerTP, TotalScore, param, BestMatch = True, BestDrift = True):
    """
    This function applies drift correction between n_days, currently this is done by alligning session 2 to session 1,
    then session 3 to session 2 etc.   
    This function, calls another function to apply the drift correction, to be able to apply different type of drift correction 
    easily.
    """
    BestPairs = np.argwhere(CandidatePairs == 1)

    #make it like the matlab code, (small unit idx, larger unit idx)
    BestPairs[:, [0,1]] = BestPairs[:, [1,0]]

    drifts = np.zeros( (param['n_days'] - 1, 3))

    for did in range(param['n_days'] - 1):
            idx = np.argwhere( ( (BestPairs[:,0] >= SessionSwitch[did]) * (BestPairs[:,0] < SessionSwitch[did + 1]) *
                                (BestPairs[:,1] >= SessionSwitch[did + 1]) * (BestPairs[:,1] < SessionSwitch[did + 2]) ) == True)

            Pairs = BestPairs[idx,:].squeeze()
            if BestMatch == True:
                Pairs = get_good_matches(Pairs, TotalScore)

            #Test to see if there are enough mathces to do drift correction pershank
            if test_matches_per_shank(Pairs, AvgCentroid, did, param) == True and BestDrift == True:
                drifts = np.zeros( (param['n_days'] - 1, param['NoShanks'], 3)) # need to changeto number of shanks!!!!!!!!!!!!!!!!!
                drifts[did,:,:], WeightedAvgWaveF_PerTP, AvgCentroid = appply_drift_correction_per_shank(Pairs, did, SessionSwitch, AvgCentroid, WeightedAvgWaveF_PerTP, param)
                print(f'Done drift correction per shank for session pair {did+1} and {did+2}')
            else:
                drifts = np.zeros( (param['n_days'] - 1, 3))
                drifts[did,:], WeightedAvgWaveF_PerTP, AvgCentroid = apply_drift_corection_basic(Pairs, did, SessionSwitch, AvgCentroid, WeightedAvgWaveF_PerTP)

    return drifts, AvgCentroid, WeightedAvgWaveF_PerTP



def get_total_score(Scores2Include, param):
    """
    Using the Scores2Include dictioanry (keys are the name of the scores/metric, values are the n_units*n_units arrays)
    Return Total Score - a normalised sum of the indivdual score (n_units,n_units)
    Predictors - the values Score2Include as a (n_units,n_units, n_scores (default 6)) array 
    """
    TotalScore = np.zeros((param['n_units'],param['n_units']))
    Predictors =  np.zeros((param['n_units'],param['n_units'], 0))


    for sid in Scores2Include:
        tmp = Scores2Include[f'{sid}']
        Predictors = np.concatenate((Predictors, np.expand_dims(tmp, axis = 2)), axis = 2)
        TotalScore += tmp

    TotalScore = (TotalScore - np.min(TotalScore)) / (np.max(TotalScore) - np.min(TotalScore))

    return TotalScore, Predictors