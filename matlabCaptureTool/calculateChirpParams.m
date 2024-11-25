function [calc_P] = calculateChirpParams(P, deviceType)

% init struct
calc_P = struct('profileId', 0,...
                'startFreq_GHz', 0,...
                'numADCSamples', 0, 'adcSamplingRate_ksps', 0,...
                'adcSamplingTime_usec',0,...
                'ttlBandwidth_MHz', 0, ...
                'validBandwidth_MHz', 0, ...
                'rangeMax_m', 0, 'rangeResolution_m', 0, ...
                'velMax_mps', 0, 'velResolution_mps', 0, ...
                'frameTime_msec', 0,...
                'activeFrameTime_msec', 0,...
                'dutyCycle_percent', 0,...
                'numRangeBins', 0, 'numDopplerBins',0,...
                'radarCubeSz_KB', 0);

% define constants
c_speed_of_light = 3E8; %299792458;
sec2usec = 1E6;
usec2msec = 1E-3;
KHz2Hz = 1E3;
MHz2Hz = 1E6;
GHz2Hz = 1E9;
MHz2GHz = 1E-3;

%% Get Antenna CFG
calc_P.numTXChannel = nnz((dec2bin(P.channelCfg.txChannelEn)=='1'));%nnz(de2bi(P.channelCfg.txChannelEn,'left-msb'));
calc_P.numRXChannel = nnz((dec2bin(P.channelCfg.rxChannelEn)=='1'));%nnz(de2bi(P.channelCfg.rxChannelEn,'right-msb'));

%% Get Frame Mode
switch (deviceType)
    case 'xWR6843/xWR1843/xWR1642'
        ADV_SF_MODE = (P.dfeDataOutputMode.modeType == 3); %else 1 = frame based mode
        % note: parsing assumes and supports only one profile ID per subframe
        if(ADV_SF_MODE)
            numSubFrames = P.advFrameCfg.numOfSubFrames;
            calc_P = repmat(calc_P, 1, numSubFrames);
        else
            numSubFrames = 0;
        end

        %% Get Chirp/Profile Info
        numProfiles = numel(P.profileCfg.profileId);

        for i=1:numProfiles
            calc_P(i).profileId = P.profileCfg.profileId(i);
            calc_P(i).startFreq_GHz = P.profileCfg.startFreq(i);

             if(P.profileCfg.freqSlopeConst(i)>=76)
                CLI_FREQ_SCALE_FACTOR = 3.6;  %77GHz
            else
                CLI_FREQ_SCALE_FACTOR = 2.7;  %60GHz
            end

            %P.profileCfg.freqSlopeConst(i) = fix(P.profileCfg.freqSlopeConst(i) * bitshift(1,26)/CLI_FREQ_SCALE_FACTOR)*(CLI_FREQ_SCALE_FACTOR/bitshift(1,26));

            calc_P(i).numADCSamples = P.profileCfg.numADCSamples(i); %numsamples/chirp
            calc_P(i).adcSamplingRate_ksps = P.profileCfg.digOutSampleRate(i);
            calc_P(i).adcSamplingTime_usec = (calc_P(i).numADCSamples/(calc_P(i).adcSamplingRate_ksps*KHz2Hz))*sec2usec; %adcSamplingTime = Tc
            calc_P(i).interChirpTime_usec = P.profileCfg.idleTime(i)+(P.profileCfg.rampEndTime(i)-calc_P(i).adcSamplingTime_usec);%(Tic)

            %Timing

            if(~ADV_SF_MODE)
                % assuming that in normal frame mode there is only one
                % defined profile within a frame
                numChirps = P.frameCfg.chirpEndIndex(1)-P.frameCfg.chirpStartIndex(1)+1;
                numLoops = P.frameCfg.numLoops(1);
                framePeriod = P.frameCfg.framePeriodicity(1);
            else
                %get chirp indices associated with profile ID
                chirpIndices = find(P.chirpCfg.profileIdentifier == P.profileCfg.profileId(i))-1;
                %get subframe num associated with chirp indices
                subFrameIndex = find(P.subFrameCfg.chirpStartIdx == chirpIndices(1));
                subFrameNum = P.subFrameCfg.subFrameNum(subFrameIndex); % this is the subframe that uses the profileID
                numChirps = P.subFrameCfg.numOfChirps(subFrameIndex);
                framePeriod = P.subFrameCfg.subFramePeriodicity(subFrameIndex);
                numLoops = P.subFrameCfg.numLoops(subFrameIndex);
            end

            % this doesn't account for the low power mode where if idleTime is >
            % 10usec the power amplifiers are turned off
            calc_P(i).numLoops = numLoops;
            calc_P(i).activeFrameTime_msec = numChirps*(P.profileCfg.idleTime(i)+P.profileCfg.rampEndTime(i))*numLoops*usec2msec; % for TDM MIMO numChirps = numTx
            calc_P(i).frameTime_msec = framePeriod;
            calc_P(i).dutyCycle_percent = (calc_P(i).activeFrameTime_msec/calc_P(i).frameTime_msec)*100;

            % Bandwidth
            calc_P(i).ttlBandwidth_MHz = P.profileCfg.rampEndTime(i) * P.profileCfg.freqSlopeConst(i);
            calc_P(i).validBandwidth_MHz = calc_P(i).adcSamplingTime_usec * P.profileCfg.freqSlopeConst(i);


            % Range Resolution
            calc_P(i).rangeResolution_m = c_speed_of_light/(2*calc_P(i).validBandwidth_MHz*MHz2Hz); 

            % Max Range
            IFmax = 0.8 * calc_P(i).adcSamplingRate_ksps; %assuming complex 1x (only output mode supported in SDK OOB) 
            % If complex2x or real mode IFmax = 0.8 * adc_sampling_frequency/2;
            calc_P(i).rangeMax_m = (IFmax*KHz2Hz)*c_speed_of_light/(2*(P.profileCfg.freqSlopeConst(i)*MHz2Hz*sec2usec));

            % Velocity Resolution
            carrier_frequency = P.profileCfg.startFreq(i);% +  P.profileCfg.freqSlopeConst(i)*MHz2GHz*(P.profileCfg.adcStartTime(i)+ calc_P(i).adcSamplingTime_usec/2);
            wavelength = c_speed_of_light/(carrier_frequency*GHz2Hz); %units in m
            calc_P(i).velResolution_mps = wavelength/(2*numLoops*calc_P(1).numTXChannel*(P.profileCfg.idleTime(1)+P.profileCfg.rampEndTime(1))/sec2usec);

            % Max Velocity (no extension)
            calc_P(i).velMax_mps = wavelength/(4*calc_P(1).numTXChannel*(P.profileCfg.idleTime(1)+P.profileCfg.rampEndTime(1))/sec2usec);

            % FFT Size
            % Number of doppler bins is the smallest power of 2 greater or equal than number of doppler chirps*/
            calc_P(i).numDopplerBins = max(bitshift(1, ceil(log2(numLoops))), 8); 
            calc_P(i).numRangeBins = bitshift(1, ceil(log2(calc_P(1).numADCSamples)));

            % Radar Cube
            bytesPerSample = 4; 
            % cube = (bytes/sample * #samples/chirp * #chirps/virtualAnt * #virtualAnt) 
            calc_P(i).radarCubeSz_KB = bytesPerSample * calc_P(1).numADCSamples * numChirps * numLoops * calc_P(1).numRXChannel/1024;
        end

    case 'xWRL6432/xWRL1432'
        numProfiles = 1;
        for i=1:numProfiles
            calc_P(i).profileId = 0;
            calc_P(i).startFreq_GHz = P.chirpTimingCfg.chirpRfFreqStart;

            calc_P(i).numADCSamples = P.chirpComnCfg.numOfAdcSamples; %numsamples/chirp
            calc_P(i).adcSamplingRate_ksps = 100e3/P.chirpComnCfg.adcSampRatio;
            calc_P(i).adcSamplingTime_usec = (calc_P(i).numADCSamples/(calc_P(i).adcSamplingRate_ksps*KHz2Hz))*sec2usec; %adcSamplingTime = Tc
            calc_P(i).interChirpTime_usec = P.chirpTimingCfg.chirpIdleTime+(P.chirpComnCfg.chirpRampEndTime(i)-calc_P(i).adcSamplingTime_usec);%(Tic)

            %Timing

            % assuming that in normal frame mode there is only one
            % defined profile within a frame
            if (P.chirpComnCfg.chirpTxMimoPatSel == 0) 
                numOfChirps = 1;
            elseif ((P.chirpComnCfg.chirpTxMimoPatSel == 1) || (P.chirpComnCfg.chirpTxMimoPatSel == 4))
                numOfChirps = 2;
            end

            % this doesn't account for the low power mode where if idleTime is >
            % 10usec the power amplifiers are turned off
            numLoops = P.frameCfg.numOfChirpsInBurst * P.frameCfg.numOfBurstsInFrame / numOfChirps;
            calc_P(i).numLoops = numLoops;
            calc_P(i).activeFrameTime_msec = P.frameCfg.numOfBurstsInFrame *P.frameCfg.burstPeriodicity*usec2msec; % for TDM MIMO numChirps = numTx
            calc_P(i).frameTime_msec = P.frameCfg.framePeriodicity;
            calc_P(i).dutyCycle_percent = (calc_P(i).activeFrameTime_msec/calc_P(i).frameTime_msec)*100;

            % Bandwidth
            calc_P(i).ttlBandwidth_MHz = P.chirpComnCfg.chirpRampEndTime(i) * P.chirpTimingCfg.chirpRfFreqSlope(i);
            calc_P(i).validBandwidth_MHz = calc_P(i).adcSamplingTime_usec * P.chirpTimingCfg.chirpRfFreqSlope(i);


            % Range Resolution
            calc_P(i).rangeResolution_m = c_speed_of_light/(2*calc_P(i).validBandwidth_MHz*MHz2Hz); 

            % Max Range
            IFmax = 0.8 * calc_P(i).adcSamplingRate_ksps/2; %assuming complex 1x (only output mode supported in SDK OOB) 
            % If complex2x or real mode IFmax = 0.8 * adc_sampling_frequency/2;
            calc_P(i).rangeMax_m = (IFmax*KHz2Hz)*c_speed_of_light/(2*(P.chirpTimingCfg.chirpRfFreqSlope(i)*MHz2Hz*sec2usec));

            % Velocity Resolution
            carrier_frequency = P.chirpTimingCfg.chirpRfFreqStart(i);% +  P.profileCfg.freqSlopeConst(i)*MHz2GHz*(P.profileCfg.adcStartTime(i)+ calc_P(i).adcSamplingTime_usec/2);
            wavelength = c_speed_of_light/(carrier_frequency*GHz2Hz); %units in m
            calc_P(i).velResolution_mps = wavelength/(2*numLoops*calc_P(1).numTXChannel*(P.chirpTimingCfg.chirpIdleTime+P.chirpComnCfg.chirpRampEndTime)/sec2usec);

            % Max Velocity (no extension)
            calc_P(i).velMax_mps = wavelength/(4*calc_P(1).numTXChannel*(P.chirpTimingCfg.chirpIdleTime+P.chirpComnCfg.chirpRampEndTime)/sec2usec);

            % FFT Size
            % Number of doppler bins is the smallest power of 2 greater or equal than number of doppler chirps*/
            calc_P(i).numDopplerBins = max(bitshift(1, ceil(log2(numLoops))), 8); 
            calc_P(i).numRangeBins = bitshift(1, ceil(log2(calc_P(1).numADCSamples)));

            % Radar Cube
            bytesPerSample = 4; 
            % cube = (bytes/sample * #samples/chirp * #chirps/virtualAnt * #virtualAnt) 
            calc_P(i).radarCubeSz_KB = bytesPerSample * calc_P(1).numADCSamples /2 * numOfChirps * numLoops * calc_P(1).numRXChannel/1024;
         end   
    
    otherwise
        warning('Unexpected device type.')
    

end

