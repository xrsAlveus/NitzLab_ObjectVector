function ObjVecProcessor
%% ObjVecProcessor
% ObjVecProcessor takes in a dvt file, the event csv files, and a spike
% data mat file and writes a .mat file with a name starting with the name
% of the dvt file.
% 
% The .mat file has interpolated light data up to acceptable gap sizes as
% well as an added "light" that is the average of the first two lights.
%
% This also includes velocity, acceleration, and head direction.
%
% Non-built-in functions called:
%      inpaint_nans
%
% By Jingyue Xu, 20220317
% Adapted from TTTrackingPreprocessor.m by Jake Olson, October 2014

clear
close all

% Prompt user to select file. Will save back to the same folder
currectDir = pwd;
recDir = uigetdir;
cd(recDir)
[dvtFileName, dvtPathName] = uigetfile(fullfile(recDir, '*.dvt'), 'Choose the dvt file.');
[objFileName, objPathName] = uigetfile(fullfile(recDir, '*lego.csv'), 'Choose the object marker file.');
[inrFileName, inrPathName] = uigetfile(fullfile(recDir, '*inner.csv'), 'Choose the inner marker file.');
[spkFileName, spkPathName] = uigetfile(fullfile(recDir, '*.mat'), 'Choose the spike data file.');
indRecStruct.dvtFileName = dvtFileName;
indRecStruct.dvtPathName = dvtPathName;

% Raw DVT file should be of the format of each row being a sample, with
% multiple columns. The columns are:
% Line Time Light1X Light1Y Light2X Light2Y ...
dvtRaw = load(fullfile(dvtPathName, dvtFileName));
workingDVT = dvtRaw;

% Read object location markers from CSV file
objRaw = readtable(fullfile(objPathName, objFileName));

% Read inner run event markers from CSV file
inrRaw = readtable(fullfile(inrPathName, inrFileName));

% Read spike time data MAT file
spkRaw = load(fullfile(spkPathName, spkFileName));

% So we can use the tracked pixel values as indices later on in analyses,
% we add one. To encode the location of the light in the DVT files, Plexon
% uses values from a range of 1-1024? w/ 0 values indicating lost tracking.
% This converts from the encoding form 1024x1024 to native pixels of camera
% 640x480, then adds 1 to the value so values are 1-640 instead of 0-639.
workingDVT(:, 3:end) = workingDVT(:, 3:end)*639/1023+1;
nRealLights = (size(dvtRaw, 2)/2)-1;

clear objFileName objPathName inrFileName inrPathName spkFileName spkPathName

%% Filling in missing position points.
% For this work, Doug is willing to fill in gaps of up to 1/2 second.
% I use points 99 and 100 just in case something strange happens in the
% startup. Sufficiently large to avoid that IMO.
sampleRate = round(1/(workingDVT(100, 2)-workingDVT(99, 2))); 
maxGap = sampleRate/2; % Half second worth of samples.

indRecStruct.trackingSampleRate = sampleRate;
indRecStruct.maxGapFilled = maxGap;

% Var Init
samplesLost = false(length(dvtRaw), nRealLights);
samplesFilled = false(length(dvtRaw), nRealLights);
samplesUnfilled = false(length(dvtRaw), nRealLights);

% Run for each light.
for iLight = 1:nRealLights
    
    %Indices of the light columns in the dvt matrix.
    lightColX = 1+iLight*2;
    lightColY = 2+iLight*2;
    
    % Find the edges of the gaps.
    lostTrackingEdges = diff([0;workingDVT(:, lightColX) == 1] &...
        [0;workingDVT(:, lightColY) == 1]);
    
    % Mark the bad points w/ NaNs.
    workingDVT(...
        (workingDVT(:,lightColX) == 1 & workingDVT(:,lightColY) == 1),...
        lightColX:lightColY) = NaN;
    samplesLost(:,iLight) = isnan(workingDVT(:,lightColX));
    
    % Interpolate values - using the inpaint_nans fn. Rounded because the
    % values are indices of pixels. Our max precision is individual pixels.
    workingDVT(:,lightColX:lightColY) = ...
        round(inpaint_nans(workingDVT(:,lightColX:lightColY)));
    
    % Find the gaps too large to fix.
    gapStarts = find(lostTrackingEdges == 1);
    gapEnds = find(lostTrackingEdges == -1);
    if ~isempty(gapStarts)
%         if gapEnds(1) < gapStarts(1) % Lost tracking at beginning. Common.
%             gapStarts = [1;gapStarts];
%         end
        if gapStarts(end) > gapEnds(end) % Lost tracking at end. Common.
            gapEnds = [gapEnds;length(workingDVT)+1]; %#ok<AGROW>
        end
        gapLengths = gapEnds - gapStarts;
        
        % "Unfix" the gaps longer than the length we are willing to
        % interpolate over - Done this way so that when the interpolation
        % algorithm runs, there are no bad data (minus spurious
        % reflections, etc.) that could bias the algorithm in a certain
        % direction.
        unfixableGaps = gapLengths > maxGap;
        for iGap = 1:length(gapStarts)
            if unfixableGaps(iGap)
                workingDVT(gapStarts(iGap):gapEnds(iGap)-1,lightColX:lightColY) = 1;
                % [1,1] light coordinate now represents lost tracking.
            end
        end
    end
    
    % So we know where we fixed.
    samplesFilled(:,iLight) = samplesLost(:,iLight) & ...
        (workingDVT(:,lightColX) ~= 1 | workingDVT(:,lightColY) ~= 1);
    
    % The gaps we couldn't fix.
    samplesUnfilled(:,iLight) = samplesLost(:,iLight) & ...
        (workingDVT(:,lightColX) == 1 & workingDVT(:,lightColY) == 1);
end

indRecStruct.samplesLost = samplesLost;
indRecStruct.samplesFilled = samplesFilled;
indRecStruct.samplesUnfilled = samplesUnfilled;

clear gap* iGap iLight lightCol* lostTrackingEdges unfixableGaps maxGap

%% Process event markers
% Obtain reward index and time
objectRaw = objRaw(objRaw.(1) == "lego" | objRaw.(1) == "Lego" ,:);
tReward = objectRaw{1:3:end, 5};

nReward = numel(tReward);
tReward = [repelem((size(workingDVT,1)+size(tReward,1)+1), nReward)', tReward];
sortReward = [workingDVT(:,1:2); tReward];
sortReward = sortrows(sortReward, 2);
indReward = (sortReward(:,1) - (1:size(sortReward, 1))') > 0;
iReward = nonzeros(indReward .* (1:size(sortReward, 1))') - (1:nReward)';
tReward(:,1) = iReward;

% Obtain reward markers
objMarker = zeros(size(objectRaw,1)/3, 8);
objMarker(:,1:2) = tReward;
objMarker(:,3:4) = objectRaw{1:3:end, 7:8};
objMarker(:,5:6) = objectRaw{2:3:end, 7:8};
objMarker(:,7:8) = objectRaw{3:3:end, 7:8};
objMarker = [(1:size(objMarker,1))' objMarker];

% Process inner and outer runs, retain rewarded runs
innerRaw = table2array(inrRaw(inrRaw.(1) == "inner" | inrRaw.(1) == "Inner", 5:6));
tInner = nan(size(innerRaw));
for i = 1:size(innerRaw, 1)
    if sum(tReward(:,2) >= innerRaw(i,1) & tReward(:,2) <= innerRaw(i,2)) > 0 % Only keep rewarded runs
        tInner(i,:) = innerRaw(i,:);
    end
end
tInner = tInner(~isnan(tInner));
tInner = reshape(tInner, numel(tInner)/2, 2);

tOuter = zeros(length(tInner)-1, 2);
tOuter(:,1) = tInner(1:end-1, 2);
tOuter(:,2) = tInner(2:end, 1);

iInner = tInner(:);
iInner = [repelem((size(workingDVT,1)+size(iInner,1)+1), size(iInner, 1))' iInner];
sortInner = [workingDVT(:,1:2); iInner];
sortInner = sortrows(sortInner, 2);
indInner = (sortInner(:,1) - (1:size(sortInner, 1))') > 0;
iInner = nonzeros(indInner .* (1:size(sortInner, 1))') - (1:size(iInner, 1))';
iInner = reshape(iInner, [size(tInner, 2) size(tInner, 1)])';

iOuter = tOuter(:);
iOuter = [repelem((size(workingDVT,1)+size(iOuter,1)+1), size(iOuter, 1))' iOuter];
sortOuter = [workingDVT(:,1:2); iOuter];
sortOuter = sortrows(sortOuter, 2);
indOuter = (sortOuter(:,1) - (1:size(sortOuter, 1))') > 0;
iOuter = nonzeros(indOuter .* (1:size(sortOuter, 1))') - (1:size(iOuter, 1))';
iOuter = reshape(iOuter, [size(tOuter, 2) size(tOuter, 1)])';

tInner = [(1:size(tInner,1))' tInner];
tOuter = [(1:size(tOuter,1))' tOuter];
iInner = [(1:size(iInner,1))' iInner];
iOuter = [(1:size(iOuter,1))' iOuter];

indRecStruct.event.tInner = tInner;
indRecStruct.event.tOuter = tOuter;
indRecStruct.event.iInner = iInner;
indRecStruct.event.iOuter = iOuter;

% % Object configuration - using KNN to classify object configuration
% 
% % Construct a prior
% x1 = [450; 500; 500; 450; 450; 500; 500; 450; 680; 740; 740; 680; 680; 740; 740; 680; 450; 450; 630; 550; 740; 740; 550; 635; 560; 620; 620; 560];
% y1 = [280; 280; 220; 220; 525; 525; 465; 465; 525; 525; 465; 465; 280; 280; 220; 220; 415; 340; 530; 500; 345; 425; 240; 240; 410; 410; 350; 350];
% x2 = [500; 500; 450; 450; 500; 500; 450; 450; 740; 740; 680; 680; 740; 740; 680; 680; 480; 420; 590; 585; 700; 770; 595; 595; 620; 620; 560; 560];
% y2 = [280; 220; 220; 280; 525; 465; 465; 525; 525; 465; 465; 525; 280; 220; 220; 280; 375; 375; 500; 540; 380; 380; 265; 210; 410; 350; 350; 410];
% Class = ["A1"; "A2"; "A3"; "A4"; "B1"; "B2"; "B3"; "B4"; "C1"; "C2"; "C3"; "C4";
%     "D1"; "D2"; "D3"; "D4"; "Ei"; "Eo"; "Fi"; "Fo"; "Gi"; "Go"; "Hi"; "Ho"; "J1"; "J2"; "J3"; "J4"];
% prior = table(x1, y1, x2, y2, Class);
% knn = fitcknn(prior, 'Class'); % Fit KNN
% X = objMarker(1,3:6);
% label = predict(knn, X);
% 
% for i = 1:size(objMarker,1)
%     vecAxy = objMarker(i,3:4) - objMarker(i,5:6);
%     theta = -atan2(vecAxy(2),vecAxy(1));
% end

indRecStruct.event.reward = objMarker;

% Process clean runs moving on

clear objRaw tReward nReward iReward ind sortReward sortInner sortOuter ...
    indInner indOuter indReward innerRaw tInner tOuter outer*

%% Create a "light" and add to DVT matrix that is the average of the first two lights.
% Var Init
avgLight = nRealLights+1; % Adding the average of the lights as a 'light'.

% Average the XY coords of the lights for the entire recording - save as 2
% new columns - a new *light* for the DVT matrix.
workingDVT(:,(1+avgLight*2)) = round(sum(workingDVT(:,3:2:1+nRealLights*2),2)/nRealLights);
workingDVT(:,(2+avgLight*2)) = round(sum(workingDVT(:,4:2:2+nRealLights*2),2)/nRealLights);

% Put [1,1] (missing light code) into the averaged columns for
% samples where one or more of the lights is lost.
notPerfectTracking = any(samplesUnfilled,2);
workingDVT(notPerfectTracking,(1+avgLight*2):(2+avgLight*2)) = 1;

clear iLight lightCol* avgLight

%% Create a mashup "light" 
% Add to DVT matrix a "light" that is the average of the
% first two lights or just the value of each individual light if the other 
% is lost.

% Var Init
mashupLight = nRealLights+2; % Adding the average of the lights as a 'light'.

% Average the XY coords of the lights for the entire recording - save as 2
% new columns - a new *light* for the DVT matrix.
workingDVT(:,(1+mashupLight*2)) = round(sum(workingDVT(:,3:2:1+nRealLights*2),2)/nRealLights);
workingDVT(:,(2+mashupLight*2)) = round(sum(workingDVT(:,4:2:2+nRealLights*2),2)/nRealLights);

% Put [1,1] (missing light code) into the averaged columns for
% samples where one or more of the lights is lost.
workingDVT(any(samplesUnfilled,2),(1+mashupLight*2):(2+mashupLight*2)) = 1;

% Fill spots where we can't average but do have 1 light (lost 1 light).
for iLight = 1:nRealLights
    % Indices of the light columns in the dvt matrix.
    lightColX = 1+iLight*2;
    lightColY = 2+iLight*2;
    thisLightIsGood = ~samplesUnfilled(:,iLight);
    workingDVT(thisLightIsGood & notPerfectTracking,(1+mashupLight*2):(2+mashupLight*2)) =...
        workingDVT(thisLightIsGood & notPerfectTracking,lightColX:lightColY);
end

% DVT processing - (interpolating and adding an average light) is finished.
processedDVT = workingDVT;
indRecStruct.world.processedDVT = processedDVT;

clear iLight lightCol* workingDVT mashupLight thisLightIsGood notPerfectTracking

%% Process object markers into object location data
% Plexon Studio encodes location in a 1024*768 resolution, this block
% converts is to the camera's 640*480 resolution

objPosition = zeros(size(processedDVT,1),6); % Getting object positions throughout recording

for i = 1:size(iInner,1)
    iMarker = iInner(i,2);
    objPosition(iMarker:end,1) = objMarker(i,4)*(640/1024); % columns 4, 5 are x, y positions for the light at arm A (right side of the angle) of the object
    objPosition(iMarker:end,2) = objMarker(i,5)*(480/768);
    objPosition(iMarker:end,3) = objMarker(i,6)*(640/1024); % columns 5, 7 are x, y positions for the light at the vertex of the object
    objPosition(iMarker:end,4) = objMarker(i,7)*(480/768);
    objPosition(iMarker:end,5) = objMarker(i,8)*(640/1024); % columns 8, 9 are x, y positions for the light at arm B (left side of the angle) of the object
    objPosition(iMarker:end,6) = objMarker(i,9)*(480/768);
end

objPosition = [processedDVT(:,1:2) objPosition];
indRecStruct.world.objPosition = objPosition;

%% Create relative DVT for object-centered position
% Apply a transformation matrix to rotate DVT to object-relative position
% This code block is written assuming there are 3 lights (A, B, C) on the
% object, where B is at the corner of the object, A is on the right to B

workingDVTRel = processedDVT;
objPositionRel = objPosition(:,3:end);

for i = 1:size(workingDVTRel,2)/2-1
    workingDVTRel(:,i*2+1:i*2+2) = workingDVTRel(:,i*2+1:i*2+2) - objPosition(:,5:6);
end

for i = 1:size(objPositionRel,2)/2
    objPositionRel(:,i*2-1:i*2) = objPositionRel(:,i*2-1:i*2) - objPosition(:,5:6);
end

for i = 1:size(workingDVTRel,1)
    vecAxy = objPositionRel(i,1:2) - objPositionRel(i,3:4); % Vector A corresponding to object x-axis
    theta = -atan2(vecAxy(2),vecAxy(1)); % Object angle relative to room coordinates
    A = [cos(theta), -sin(theta); sin(theta), cos(theta)]; % Create a rotation matrix
    
    for j = 1:size(workingDVTRel,2)/2-1
        if workingDVTRel(i,j*2+1) ~= 1 && workingDVTRel(i,j*2+1) ~= 1
            workingDVTRel(i,j*2+1:j*2+2) = (A*workingDVTRel(i,j*2+1:j*2+2)')'; % Convert into object-relative coordinates 
        end
    end
    
    for j = 1:size(objPositionRel,2)/2
        objPositionRel(i,j*2-1:j*2) = (A*objPositionRel(i,j*2-1:j*2)')';
    end
end

% for i = 1:size(workingDVTRel,2)/2-1
%     workingDVTRel(:,i*2+1:i*2+2) = workingDVTRel(:,i*2+1:i*2+2) + objPosition(:,3:4);
% end
% 
% for i = 1:size(objPositionRel,2)/2
%     objPositionRel(:,i*2-1:i*2) = objPositionRel(:,i*2-1:i*2) + objPosition(:,3:4);
% end

objPositionRel = [processedDVT(:,1:2) objPositionRel];
indRecStruct.object.processedDVT = workingDVTRel;
indRecStruct.object.objPosition = objPositionRel;

%% Velocity & Acceleration - Averaged over adaptable window (updated with object-centered direction)
% Initialize window size to use - can change here if desired.
velSmoothWinSecs = 1/10; % Uses position change over X sec to calc vel.
velSmoothWinSamples = round(sampleRate*velSmoothWinSecs);

% Output Variable Init
vel = nan(length(processedDVT)-velSmoothWinSamples,2,nRealLights);
acc = nan(length(vel)-1,2,nRealLights); % Compare point by point vel since they are already smoothed.
instVel = nan(length(processedDVT)-1,2,nRealLights); % Instantaneous (sample rate) velocity
instAcc = nan(length(instVel)-1,2,nRealLights); % Compare point by point vel since they are already smoothed.

velRel = nan(size(vel));
accRel = nan(size(acc));
instVelRel = nan(size(instVel));
instAccRel = nan(size(instAcc));

vecAxy = objPosition(:,3:4) - objPosition(:,5:6); % Get array of object directions
theta = -atan2(vecAxy(:,2),vecAxy(:,1));

for iLight = 1:nRealLights
    lightColX = 1+iLight*2;
    lightColY = 2+iLight*2;
    
    lightLow = processedDVT(1:end-velSmoothWinSamples,lightColX:lightColY);
    lightLow(repmat(samplesUnfilled(1:end-velSmoothWinSamples,iLight),1,2)) = NaN;
    lightHigh = processedDVT(1+velSmoothWinSamples:end,lightColX:lightColY);
    lightHigh(repmat(samplesUnfilled(1+velSmoothWinSamples:end,iLight),1,2)) = NaN;
    xyVel = lightHigh - lightLow;
    
    velMag = sqrt(sum((xyVel.^2),2))/velSmoothWinSecs; % In pixels/second.
    velDirection = atan2(xyVel(:,2),xyVel(:,1)); % -pi : pi
    vel(:,:,iLight) = [velMag,velDirection];
    xyAcc = diff(xyVel);
    
    accMag = sqrt(sum((xyAcc.^2),2))*sampleRate; % In pixels/second^2.
    accDirection = atan2(xyAcc(:,2),xyAcc(:,1)); % -pi : pi
    acc(:,:,iLight) = [accMag,accDirection];
    
    instXYVel = diff(processedDVT(:,lightColX:lightColY));
    instVelMag = sqrt(sum((instXYVel.^2),2))*sampleRate; % In pixels/second.
    instVelDirection = atan2(instXYVel(:,2),instXYVel(:,1)); % -pi : pi
    instVel(:,:,iLight) = [instVelMag,instVelDirection];
    instXYAcc = diff(instXYVel);
    instAccMag = sqrt(sum((instXYAcc.^2),2))*sampleRate; % In pixels/second.
    instAccDirection =  atan2(instXYAcc(:,2),instXYAcc(:,1)); % -pi : pi
    instAcc(:,:,iLight) = [instAccMag,instAccDirection];
    
    % Store relative orientations
    velDirectionRel = velDirection + theta(1:length(velDirection));
    velRel(:,:,iLight) = [velMag,velDirectionRel];
    velRel(velRel > pi) = rem(velRel(velRel > pi), pi);
    velRel(velRel < -pi) = rem(velRel(velRel < -pi), pi);

    accDirectionRel = accDirection + theta(1:length(accDirection));
    accRel(:,:,iLight) = [accMag,accDirectionRel];
    accRel(accRel > pi) = rem(accRel(accRel > pi), pi);
    accRel(accRel < -pi) = rem(accRel(accRel < -pi), pi);

    instVelDirectionRel = instVelDirection + theta(1:length(instVelDirection));
    instVelDirectionRel(instVelDirectionRel > pi) = rem(instVelDirectionRel(instVelDirectionRel > pi), pi);
    instVelDirectionRel(instVelDirectionRel < -pi) = rem(instVelDirectionRel(instVelDirectionRel < -pi), pi);
    instVelRel(:,:,iLight) = [instVelMag,instVelDirectionRel];

    instAccDirectionRel = instAccDirection + theta(1:length(instAccDirection));
    instAccDirectionRel(instAccDirectionRel > pi) = rem(instAccDirectionRel(instAccDirectionRel > pi), pi);
    instAccDirectionRel(instAccDirectionRel < -pi) = rem(instAccDirectionRel(instAccDirectionRel < -pi), pi);
    instAccRel(:,:,iLight) = [instAccMag,instAccDirectionRel];
end

indRecStruct.world.velInst = instVel;
indRecStruct.world.accInst = instAcc;
indRecStruct.world.velSmoothed = vel;
indRecStruct.world.accSmoothed = acc;

indRecStruct.object.velInst = instVelRel;
indRecStruct.object.accInst = instAccRel;
indRecStruct.object.velSmoothed = velRel;
indRecStruct.object.accSmoothed = accRel;

clear bufferDistance iPos iLight light* xyDiff speed*  velMag ...
    velDirection* accMag accDirection* inst*

%% Head Direction
light1 = processedDVT(:,3:4);
light2 = processedDVT(:,5:6);

posDiff = light1-light2;
HDRadians = atan2(posDiff(:,2),posDiff(:,1));
HDRadians((samplesLost(:,1) & ~samplesFilled(:,1)) | ...
    (samplesLost(:,2) & ~samplesFilled(:,2))) = NaN;
indRecStruct.world.HDRadians = HDRadians;

% Relative Head Direction
HDRadiansRel = HDRadians + theta(1:length(HDRadians));
HDRadiansRel(HDRadiansRel > pi) = rem(HDRadiansRel(HDRadiansRel > pi), pi);
HDRadiansRel(HDRadiansRel < -pi) = rem(HDRadiansRel(HDRadiansRel < -pi), pi);
indRecStruct.object.HDRadians = HDRadiansRel;

% Output Check Code
% [count,center] = hist(HDRadians,36);
% sortedRows = sortrows([count;center]',1);

clear posDiff light* vecAxy theta HDRadians

%% Object-vector
disp = processedDVT(:,9:10) - objPosition(:,5:6); % Displacement vector between mash-up and object vertex
objVec = zeros(size(processedDVT,1),4);
objVec(:,1:2) = processedDVT(:,1:2);
[objVec(:,3), objVec(:,4)] = cart2pol(disp(:,1), disp(:,2));
objVecRel = repmat(objVec, 1);
objVecRel(:,3) = HDRadiansRel;

indRecStruct.world.objVec = objVec;
indRecStruct.object.objVec = objVecRel;

clear disp processedDVT HDRadiansRel objVecRel

%% Process pre- and post-reward phases
preReward = zeros(size(iInner));
preReward(:,1:2) = iInner(:,1:2);
postReward = zeros(size(iInner));
postReward(:,[1,3]) = iInner(:,[1,3]);

meanArmL = mean([vecnorm((objMarker(:,3:4)-objMarker(:,6:7))'), vecnorm((objMarker(:,8:9)-objMarker(:,5:6))')])/2;

for i = 1:size(iInner, 1)
    iReward = objMarker(i,2);
    preReward(i,3) = find((objVec(1:iReward,4) >= meanArmL*1.5), 1, 'last');
    postReward(i,2) = iReward + find((objVec(iReward:size(vel,1),4) >= meanArmL*1.5), 1);
end

indRecStruct.event.preReward = preReward;
indRecStruct.event.postReward = postReward;
indRecStruct.event.runNumber = size(iInner,1);

clear iInner objVec objMarker preReward postReward meanArmL

%% Save results - indRecStruct
indRecStruct.spike = spkRaw;

args = input('Save data? yes/no (y/n)','s');
if (args == "yes") | (args == 'y') %#ok<OR2>
    save(fullfile(dvtPathName,strcat(dvtFileName(1:end-4),'_indRecStruct')), 'indRecStruct');
end

clear args

%% Visualize tracking and object position data
args = input('Plot data? yes/no (y/n)','s');
if (args == "yes") | (args == 'y') %#ok<OR2>
    figure
    hold on
    scatter(indRecStruct.world.processedDVT(:,9), indRecStruct.world.processedDVT(:,10), '.', 'MarkerEdgeColor', [0 0.4470 0.7410])
    scatter(indRecStruct.world.objPosition(:,[3,5,7]), indRecStruct.world.objPosition(:,[4,6,8]), 200, '.', 'MarkerEdgeColor', '#D95319')
    xlim([0 660])
    ylim([0 500])
    hold off
    
    saveas(gcf, string(recDir) + filesep + "ProcessedDVT.png")
    
    args = input('Plot object relative data? yes/no (y/n)','s');
    % Scatter run and object data
    if (args == "yes") | (args == 'y') %#ok<OR2>
        figure
        hold on
        scatter(indRecStruct.object.processedDVT(:,9), indRecStruct.object.processedDVT(:,10), '.', 'MarkerEdgeColor', [0 0.4470 0.7410])
        scatter(indRecStruct.object.objPosition(:,[3,5,7]), indRecStruct.object.objPosition(:,[4,6,8]), 200, '.', 'MarkerEdgeColor', '#D95319')
        xlim([-660 660])
        ylim([-500 500])        
        hold off
        
        saveas(gcf, string(recDir) + filesep + "ProcessedDVT_ObjVec.png")
    end
end

cd(currectDir)
%% Notes

% -[x] Make three lights on the object
% -[x] Shift numbers to positive
% -[x] Calculate distance to object
% -[x] Draw positional vectors with angle at some interval
% -[x] let the data tell you

% # Events
% ## Internal run
% Hard code gate locations
% Find stop events which correspond to getting the reward
% Find the previous crossing in and the next crossing out to define internal run
% 
% ## External run
% External run in between
% Clean/dirty run
% 
% # Maps
% ## Linearized rate map
% Need neuron data (20221114)
% 
% ## Rate map mapped against distance (need neuron data)
% At particular distance and orientation, how many spikes occurred
% Need neuron datva (20221114)
% 
% ### Occupancy map
% Matrix of zeros of the same size as the tracking, always centering at the object
% Update to get map for each inner run (20221114)
% 
% ### Spike map
% Based on occupancy map, how many spike occurred in a 1/60 s time window
% Need neuron data (20221114)


% Deal with cell phone
% Count unfixable gaps