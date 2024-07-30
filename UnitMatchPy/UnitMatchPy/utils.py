# utility function for loading files etc
import numpy as np
import pandas as pd
import os
import matplotlib.pyplot as plt

def load_tsv(path):
    """
    Loadsa .tsv file as a numpy array, with the headers removed

    Parameters
    ----------
    path : str
        The path to the tsv to load

    Returns
    -------
    ndarray
        The tsv as a ndarray
    """
    df  = pd.read_csv(path, sep='\t', skiprows = 0)
    return df.values

def get_session_number(unit_id, session_switch):
    """
    Finds the session number of a unit given its id and the session_switch array

    Parameters
    ----------
    unit_id : int
        The UnitMatch unit id
    session_switch : ndarray
        A array which marks at which units the a new session starts

    Returns
    -------
    int
        The session number of the unit
    """
    for i in range(len(session_switch) - 1):
        if (session_switch[i] <= unit_id < session_switch[i+1]):
            return i

def get_session_data(n_units_per_session):
    """
    Calculates information on the sessions using the number of units per session

    Parameters
    ----------
    n_units_per_session : ndarray
        An array where each value is how many units appeared in the session

    Returns
    -------
    ndarrays
        The calculated session information
    """
    n_sessions = len(n_units_per_session)
    #Total number of units                  
    n_units = n_units_per_session.sum()

    sessionid = np.zeros(n_units, dtype = int)
    #What units the a new session starts
    session_switch = np.cumsum(n_units_per_session)
    session_switch = np.insert(session_switch, 0, 0)
    for i in range(n_sessions):
        #The session id for each unit
        sessionid[session_switch[i]:session_switch[i+1]] = int(i)

    return n_units, sessionid, session_switch, n_sessions

def get_within_session(session_id, param):
    """
    Creates an array with 1 if the units are in the same session and a 0 otherwise

    Parameters
    ----------
    session_id : ndarray
        The session id for each unit
    param : dict
        the param dictionary

    Returns
    -------
    ndarray
        A n_unit * n_unit array which marks units in the same session
    """
    n_units = param['n_units']

    tmp1 = np.expand_dims(session_id , axis=1)
    tmp2 = np.expand_dims(session_id, axis=0)

    within_session = np.ones((n_units, n_units))
    within_session[tmp1 == tmp2] = 0

    return within_session

def load_good_waveforms(wave_paths, unit_label_paths, param, good_units_only = True):
    """
    Using paths to the KiloSort data this function will load in all (good) waveforms 
    and other necessary data for UnitMatch.

    Parameters
    ----------
    wave_paths : list
        A list were each entry is a path to the RawWaveforms directory for each session
    unit_label_paths : list
        A list were each entry is a path to either BombCell good units (cluster_bc_unitType.tsv)
        or the KiloSort good units (cluster_group.tsv') for each session
    param : dict
        the param dictionary
    good_units_only : bool, optional
        If True will only load units marked as good , by default True

    Returns
    -------
    The loaded in data and updated param dictionary
    """
    if len(wave_paths) == len(unit_label_paths):
        n_sessions = len(wave_paths)
    else:
        print('Warning: gave different number of paths for waveforms and labels!')
        return

    good_units = []
    n_units_per_session_all = []

    for i in range(len(unit_label_paths)):
    #see if bombcell unit labels
        if os.path.split(unit_label_paths[0])[1] == 'cluster_bc_unitType.tsv':
            unit_label = load_tsv(unit_label_paths[i])
            tmp_idx = np.array([s for s in unit_label if 'GOOD' in s or 'NON-SOMA GOOD' in s])[:,0].astype(np.int32)
        else:
            unit_label = load_tsv(unit_label_paths[i])
            tmp_idx = np.argwhere(unit_label[:,1] == 'good')

        n_units_per_session_all.append(unit_label.shape[0])
        good_unit_idx = unit_label[tmp_idx, 0]
        good_units.append(good_unit_idx)

    waveforms = []
    if good_units_only:
    #go through each session and load in units to waveforms list
        for ls in range(len(wave_paths)):
            #load in the first good unit, to get the shape of each waveform
            p_file = os.path.join(wave_paths[ls],f'Unit{int(good_units[ls][0].squeeze())}_RawSpikes.npy')
            tmp = np.load(p_file)
            tmp_waveform = np.zeros( (len(good_units[ls]), tmp.shape[0], tmp.shape[1], tmp.shape[2]))

            for i in range(len(good_units[ls])):
                #loads in all GoodUnits for that session
                p_file_good = os.path.join(wave_paths[ls],f'Unit{int(good_units[ls][i].squeeze())}_RawSpikes.npy')
                tmp_waveform[i] = np.load(p_file_good)
            #adds that session to the list
            waveforms.append(tmp_waveform)

        del tmp_waveform
        del tmp
    
    else:
        for ls in range(len(wave_paths)):
            #load in the first good unit, to get the shape of each waveform
            p_file = os.path.join(wave_paths[ls],f'Unit{int(good_units[ls][0].squeeze())}_RawSpikes.npy')
            tmp = np.load(p_file)
            tmp_waveform = np.zeros( (len(os.listdir(wave_paths[ls])), tmp.shape[0], tmp.shape[1], tmp.shape[2]))

            for i in range(len(os.listdir(wave_paths[ls]))):
                #loads in all GoodUnits for that session
                p_file_good = os.path.join(wave_paths[ls], f'Unit{int(good_units[ls][0].squeeze())}_RawSpikes.npy')
                tmp_waveform[i] = np.load(p_file_good)
            #adds that session to the list
            waveforms.append(tmp_waveform)

        del tmp_waveform
        del tmp


    n_units_per_session = np.zeros(n_sessions, dtype = 'int')
    waveform = np.array([])

    #add all of the individual waveforms to one waveform array
    for i in range(n_sessions):
        if i == 0:
            waveform = waveforms[i] 
        else:
            waveform = np.concatenate((waveform, waveforms[i]), axis = 0)

        n_units_per_session[i] = waveforms[i].shape[0]

    param['n_units'], session_id, session_switch, param['n_sessions'] = get_session_data(n_units_per_session)
    within_session = get_within_session(session_id, param)
    param['n_channels'] = waveform.shape[2]
    param['n_units_per_session'] = n_units_per_session_all

    #if the set of default paramaters have a different spike width update these parameters
    if param['spike_width'] != waveform.shape[1]:
        param['spike_width'] = waveform.shape[1]
        param['peak_loc'] = np.floor(waveform.shape[1]/2).astype(int)
        param['waveidx'] = np.arange(param['peak_loc'] - 8,  param['peak_loc'] + 15, dtype = int)

    return waveform, session_id, session_switch, within_session, good_units, param

def get_good_units(unit_label_paths, good = True):
    """
    This function is used if you want to find good units then load them in
    (first half of load_good_waveforms)

    Parameters
    ----------
    unit_label_paths : list
        A list were each entry is a path to either BombCell good units (cluster_bc_unitType.tsv)
        or the KiloSort good units (cluster_group.tsv') for each session
    good : bool, optional
        If True will only load in units marked good
        If False will load all units labeled in the given .tsv, by default True

    Returns
    -------
    ndarray
        A list of all the good unit ids
    """
    good_units = []
    for i in range(len(unit_label_paths)):
    #see if bombcell unit labels
        if os.path.split(unit_label_paths[0])[1] == 'cluster_bc_unitType.tsv':
            unit_label = load_tsv(unit_label_paths[i])
            if good == True:
                tmp_idx = np.array([s for s in unit_label if 'GOOD' in s or 'NON-SOMA GOOD' in s])[:,0].astype(np.int32)
            else:
                tmp_idx = unit_label[:,0].astype(np.int32)
        else:
            unit_label = load_tsv(unit_label_paths[i])
            if good == True:
                tmp_idx = np.argwhere(unit_label[:,1] == 'good')
            else:
                tmp_idx = unit_label[:,0].astype(np.int32) # every unit index in the first column
                
        good_unit_idx = unit_label[tmp_idx, 0]
        good_units.append(good_unit_idx)
    return good_units

def load_good_units(good_units, wave_paths, param):
    """
    This function will load in data from a RawWaveform directory
    (second half of load_good_waveforms)

    Parameters
    ----------
    good_units : ndarray
        A array of the good unit ids (see get_good_units)
    wave_paths : list
        A list of path to the RawWaveform directory for each session
    param : dict
        The param dictionary

    Returns
    -------
    The loaded in data and updated param dictionary
    """
    if len(wave_paths) == len(good_units):
        n_sessions = len(wave_paths)
    else:
        print('Warning: gave different number of paths for waveforms and labels!')
        return
    
    waveforms = []
    #go through each session and load in units to waveforms list
    for ls in range(len(wave_paths)):
        #load in the first good unit, to get the shape of each waveform
        tmp_path = os.path.join(wave_paths[ls], f'Unit{int(good_units[ls][0].squeeze())}_RawSpikes.npy')
        tmp = np.load(tmp_path)
        tmp_waveform = np.zeros( (len(good_units[ls]), tmp.shape[0], tmp.shape[1], tmp.shape[2]))

        for i in range(len(good_units[ls])):
            #loads in all GoodUnits for that session
            tmp_path_good = os.path.join(wave_paths[ls], f'Unit{int(good_units[ls][i].squeeze())}_RawSpikes.npy')
            tmp_waveform[i] = np.load(tmp_path_good)
        #adds that session to the list
        waveforms.append(tmp_waveform)

    del tmp_waveform
    del tmp

    n_units_per_session = np.zeros(n_sessions, dtype = 'int')
    waveform = np.array([])

    #add all of the individual waveforms to one waveform array
    for i in range(n_sessions):
        if i == 0:
            waveform = waveforms[i] 
        else:
            waveform = np.concatenate((waveform, waveforms[i]), axis = 0)

        n_units_per_session[i] = waveforms[i].shape[0]

    param['n_units'], session_id, session_switch, param['n_sessions'] = get_session_data(n_units_per_session)
    within_session = get_within_session(session_id, param)
    param['n_channels'] = waveform.shape[2]
    return waveform, session_id, session_switch, within_session, param

def evaluate_output(output_prob, param, within_session, session_switch, match_threshold = 0.5):
    """
    This function evaluates summary values for the UnitMatch results by finding:
    The number of units matched to themselves across cv
    The false negative %, how many did not match to themselves across cv
    the false positive % in two ways, how many miss-matches are there in the off-diagonal per session
    and how many  false match out of how many matches we should get

    Parameters
    ----------
    output_prob : ndarray (n_units, n_units)
        The output match probability array
    param : dict
        The param dictionary
    within_session : ndarray
        The array which marks units pairs in the same session
    session_switch : ndarray
        The array which marks when a new session starts
    match_threshold : float, optional
        The threshold value which decides matches, by default 0.5
    """

    output_threshold = np.zeros_like(output_prob)
    output_threshold[output_prob > match_threshold] = 1

    # get the number of diagonal matches
    n_diag = np.sum(output_threshold[np.eye(param['n_units']).astype(bool)])
    self_match = n_diag / param['n_units'] *100
    print(f'The percentage of units matched to themselves is: {self_match}%')
    print(f'The percentage of false -ve\'s then is: {100 - self_match}% \n')

    #off-diagonal miss-matches
    n_off_diag = np.zeros_like(output_prob)
    n_off_diag = output_threshold
    n_off_diag[within_session == 1] = 0 
    n_off_diag[np.eye(param['n_units']) == 1] = 0 
    false_positive_est =  n_off_diag.sum() / (param['n_units']) 
    print(f'The rate of miss-match(es) per expected match {false_positive_est}')


    #compute matlab FP per session per session
    false_positive_est_per_session = np.zeros(param['n_sessions'])
    for did in range(param['n_sessions']):
        tmp_diag = output_threshold[session_switch[did]:session_switch[did + 1], session_switch[did]:session_switch[did + 1]]
        n_units = tmp_diag.shape[0]
        tmp_diag[np.eye(n_units) == 1] = 0 
        false_positive_est_per_session[did] = tmp_diag.sum() / (n_units ** 2 - n_units) * 100
        print(f'The percentage of false +ve\'s is {false_positive_est_per_session[did]}% for session {did +1}')

    print('\nThis assumes that the spike sorter has made no mistakes')

def curate_matches(matches_GUI, is_match, not_match, mode = 'and'):
    """
    There are two options, 'and' 'or'. 
    'And' gives a match if both CV give it as a match
    'Or gives a match if either CV gives it as a match

    Parameters
    ----------
    matches_GUI : ndarray
        The array of matches calculated for the GUI  
    is_match : list
        A list of pairs manually curated as a match in the GUI
    not_match : list
        A list of pairs manually curated as NOT a match in the GUI
    mode : str, optional
        either 'and' or  'or' depending on preferred rules of CV concatenation, by default 'and'

    Returns
    -------
    ndarrary
        The curated list of matches
    """
    matches_a = matches_GUI[0]
    matches_b = matches_GUI[1]
    #if both arrays are empty leave function
    if np.logical_and(len(is_match) == 0, len(not_match) == 0):
        print('There are no curated matches/none matches')
        return None
    #if one array is empty make it have corrected shape
    if len(is_match) == 0:
        is_match = np.zeros((0,2))
    else:
        is_match = np.array(is_match)

    if len(not_match) == 0:
        not_match = np.zeros((0,2))
    else:
        not_match = np.array(not_match)


    if mode == 'and':
        matches_tmp = np.concatenate((matches_a, matches_b), axis = 0)
        matches_tmp, counts = np.unique(matches_tmp, return_counts = True, axis = 0)
        matches = matches_tmp[counts == 2]
    elif mode == 'or':
        matches = np.unique(np.concatenate((matches_a, matches_b), axis = 0), axis = 0)
    else:
        print('please make mode = \'and\') or \'or\' ')
        return None   
        
    #add matches in IS Matches
    matches = np.unique(np.concatenate((matches, is_match), axis = 0), axis = 0)
    print(matches.shape)
    #remove Matches in NotMatch
    matches_tmp = np.concatenate((matches, not_match), axis = 0)
    matches_tmp, counts = np.unique(matches_tmp, return_counts = True, axis = 0)
    matches = matches_tmp[counts == 1]

    return matches

def fill_missing_pos(KS_dir, n_channels):
    """
    KiloSort (especially in 4.0) may not include channel positions for inactive channels, 
    as UnitMatch require the full channel_pos array this function will extrapolate it from the given channel positions

    Parameters
    ----------
    KS_dir : str
        The path to the KiloSort directory
    n_channels : int
        The number of channels 

    Returns
    -------
    ndarray
        The full channel_pos array
    """
    print('The channel_positions.npy file does not match with the raw waveforms \n \
           we have attempted to fill in the missing positions, please check the attempt worked and examine the channel_positions and RawWaveforms shape')
    path_tmp = os.path.join(KS_dir, 'channel_positions.npy')
    pos = np.load(path_tmp)

    path_tmp = os.path.join(KS_dir, 'channel_map.npy')
    channel_map = np.load(path_tmp).squeeze()

    channel_pos = np.full((n_channels,2), np.nan)
    channel_pos[channel_map,:] = pos

    channel_pos_new = []
    #get the unique x positions
    x_unique = np.unique(channel_pos[:,0])
    x_unique = x_unique[~np.isnan(x_unique)]

    #go through each column
    for x in x_unique:
        #get the known y-values for that column
        y_column = channel_pos[np.argwhere(channel_pos[:,0] == x), 1].squeeze()

        #test to see if any other columns have the same set of y positions
        same_x_pattern = np.unique(channel_pos[np.in1d(channel_pos[:,1], y_column), 0])
        same_y_pattern = channel_pos[np.in1d(channel_pos[:,0], same_x_pattern), 1]

        #find the mode difference, i.e the steps between y-positions 
        y_steps, y_step_counts = np.unique(np.diff(np.unique(same_y_pattern)), return_counts= True)
        y_steps = y_steps[np.argmax(y_step_counts)].astype(int)

        #find the min/max y-positions to fill in all positions for the column
        ymin = np.min(same_y_pattern).astype(int)
        ymax = np.max(same_y_pattern).astype(int)
        ypos = np.arange(ymin, ymax+y_steps, y_steps)

        channel_pos_column = np.stack((np.full_like(ypos,x), ypos)).T
        channel_pos_new.append(channel_pos_column)


    n_unique_x = x_unique.shape[0]

    channel_pos_fill = np.zeros_like(channel_pos)
    for i, x in enumerate(x_unique):
        #find which sequence of positions this x-column fills 
        x_point = np.argwhere(channel_pos[:,0] == x).squeeze()[0]
        start = x_point % n_unique_x
        points = np.arange(start, n_channels, n_unique_x)
        #fill in the positions for this column
        for j, point in enumerate(points):
            channel_pos_fill[point,:] = channel_pos_new[i][j,:]

    if np.sum(channel_pos == channel_pos_fill) //2 == pos.shape[0]:
        print('Likely to be correctly filled')
        return channel_pos_fill
    else:
        print('Error in filling channel positions')
        return channel_pos_fill


def paths_from_KS(KS_dirs):
    """
    This function will find specific paths to required files from a KiloSort directory

    Parameters
    ----------
    KS_dirs : list
        The list of paths to the KiloSort directory for each session

    Returns
    -------
    list
        The lists to the files for each session
    """
    n_sessions = len(KS_dirs)

    #load in the number of channels
    tmp = os.getcwd()

    wave_paths = []
    for i in range(n_sessions):
        #check if it is in KS directory
        if os.path.exists(os.path.join(KS_dirs[i], 'RawWaveforms')):
            wave_paths.append( os.path.join(KS_dirs[i], 'RawWaveforms'))
        #Raw waveforms curated via bombcell
        elif os.path.exists(os.path.join(KS_dirs[i], 'qMetrics', 'RawWaveforms')):
            wave_paths.append( os.path.join(KS_dirs[i],'qMetrics', 'RawWaveforms'))
        else:
            raise Exception('Could not find RawWaveforms folder')
    #load in a waveform from each session to get the number of channels!
    n_channels = []
    for i in range(n_sessions):
        path_tmp = wave_paths[i]
        file = os.listdir(path_tmp)
        waveform_tmp = np.load(os.path.join(path_tmp,file[0]))
        n_channels.append(waveform_tmp.shape[1])

    os.chdir(tmp)

    #Load channel_pos
    channel_pos = []
    for i in range(n_sessions):
        path_tmp = os.path.join(KS_dirs[i], 'channel_positions.npy')
        pos_tmp = np.load(path_tmp)
        if pos_tmp.shape[0] != n_channels[i]:
            print('Attmepting to fill in missing channel positions')
            pos_tmp = fill_missing_pos(KS_dirs[i], n_channels[i])

        #  Want 3-D positions, however at the moment code only needs 2-D so add 1's to 0 axis position
        pos_tmp = np.insert(pos_tmp, 0, np.ones(pos_tmp.shape[0]), axis = 1)
        channel_pos.append(pos_tmp)

    unit_label_paths = []
    # load Good unit Paths
    for i in range(n_sessions):
        if os.path.exists(os.path.join(KS_dirs[i], 'cluster_bc_unitType.tsv')):
           unit_label_paths.append( os.path.join(KS_dirs[i], 'cluster_bc_unitType.tsv')) 
           print('Using BombCell: cluster_bc_unitType')
        else:
            unit_label_paths.append( os.path.join(KS_dirs[i], 'cluster_group.tsv'))
            print('Using cluster_group.tsv')

    wave_paths = []
    for i in range(n_sessions):
        #check if it is in KS directory
        if os.path.exists(os.path.join(KS_dirs[i], 'RawWaveforms')):
            wave_paths.append( os.path.join(KS_dirs[i], 'RawWaveforms'))
        #Raw waveforms curated via bombcell
        elif os.path.exists(os.path.join(KS_dirs[i], 'qMetrics', 'RawWaveforms')):
            wave_paths.append( os.path.join(KS_dirs[i],'qMetrics', 'RawWaveforms'))
        else:
            raise Exception('Could not find RawWaveforms folder')
    
    return wave_paths, unit_label_paths, channel_pos