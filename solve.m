function [NQTmax, NQQmax, fopt, Ropt, mopt, PMFopt] = solve( p_gb, p_bg, bw, vs, fr, piv )

PACKET_SIZE = 200;
SEARCH_PERSISTENCE = 4*(p_gb/.05);

fprintf('##### Sending rate = %d kbps\n', bw)

% total #packets at this sending rate
totNumPack = floor( bw * vs.ipr / (0.008*PACKET_SIZE) );

%% Start the search
Qmax = 0;

for f = fr
    
    vs.f = f;
    vs.N = vs.f * vs.ipr;
    
    vs = intraPeriodStruct( vs );
    vs = frameSizeModel( vs );
    
    if p_bg + p_gb ~= 1
        if exist( 'markov.mat', file )
            load markov.mat
            assert( size(markov.L0,1) >= totNumPack )
        else
            markov = create_prob_struct( p_bg, p_gb, totNumPack );
            save markov.mat markov
        end
    end
    
    prevk = zeros(vs.N,1); descending = 0;
    m = zeros(vs.N,1); 
    
    highest_Q_so_far = 0; 
    best_rate_so_far = 0; 
    best_pmf_so_far = 0;
    highest_NQT_so_far = 0; 
    highest_NQQ_so_far = 0;
    
    for R = ceil(bw * piv) : -1 : 50
        
        k = ceil( estimFrameSz(vs,R) / PACKET_SIZE );
        
        if all( k == prevk ) || totNumPack < sum(k)
            continue; 
        else
            prevk = k;
        end
        
        fprintf('%d Hz, %d kbps: ', vs.f, R)
        
        if p_bg + p_gb ~= 1
            [m, NQT, pmf] = gfsmar( totNumPack-sum(k+m), k, markov, vs, m );
        else
            [m, NQT, pmf] = gfsiid( totNumPack-sum(k+m), k, p_gb, vs, m );
        end
        
        q = vs.q0 * ( (R/vs.R0)*(vs.f/vs.fmax)^-vs.beta_f )^(-1/vs.beta_q);
        NQQ = mnqq(q,vs.alpha_q,vs.qmin);     
        Q = NQQ * NQT;
        
        fprintf('NQT = %f, NQQ = %f, Q = %f ',NQT,NQQ,Q);
        
        if Q > highest_Q_so_far
            fprintf('++\n');
            descending = 0;
            best_pmf_so_far = pmf;
            highest_Q_so_far = Q;
            highest_NQT_so_far = NQT;
            highest_NQQ_so_far = NQQ;
            best_rate_so_far = R;
            best_alloc_so_far = m;
        else
            fprintf('--\n');
            descending = descending + 1;
            if descending > SEARCH_PERSISTENCE
                fprintf('>> R = %d selected for f = %d\n', best_rate_so_far, f);
                break;
            end
        end
    end

    if highest_Q_so_far > Qmax
        Qmax = highest_Q_so_far;
        NQTmax = highest_NQT_so_far;
        NQQmax = highest_NQQ_so_far;
        PMFopt = best_pmf_so_far;
        fopt = f;
        Ropt = best_rate_so_far;
        mopt = best_alloc_so_far;
    end
    fprintf('### %d Hz selected and R = %d\n', fopt, Ropt);
end

return

function vs = intraPeriodStruct( vs )

    L = vs.L;
    N = vs.N;
    
    ref = zeros(1,N);
    gop = 2^(L-1);
    all_indices_so_far = 1 : gop : N;
    
    for i = all_indices_so_far
        ref(i) = N-i;
    end
    
    while length(all_indices_so_far) < N
        gop = gop/2;
        ref( all_indices_so_far + gop ) = gop - 1;
        all_indices_so_far = [all_indices_so_far, all_indices_so_far + gop];
    end

    vs.ref = ref;

    layermap = zeros(N,1);
    for layer = L : -1 : 1   
        layermap(mod(0:N-1,2^(L-layer))==0) = layer;
    end

    vs.layermap = layermap;

    vs.t = create_hierP_tree( L, N );

return

function t = create_hierP_tree( L, N )

gop = 2^(L-1);
G = N / gop;
t = tree(1);
for b = 2:G
    t = t.addnode(b-1,1+(b-1)*gop);
end

while nnodes(t) ~= N
    gop = gop / 2;
    for node = t.nodeorderiterator
        index = t.get( node );
        t = t.addnode( node, index + gop );
    end
end

return

function vs = frameSizeModel( vs )
    
    maxValidTargetBitrate = 1200;
    
    path = ['data/',vs.video,'-',vs.vidsize,'-',strcat(...
        num2str(vs.f),'.0'),'-',num2str(vs.f * vs.ipr),'-',num2str(vs.L),'/'];
    [Lengths, ~, Target_BitRates] = parse_log_files( path ); 
    
    % choose valid bitrates if need be
    valid = Target_BitRates <= maxValidTargetBitrate;
    numValid = sum(valid);
    Lengths = Lengths(:,valid);
    
    meanFrmSz = zeros( vs.L+1, numValid ); % average frame lengths in each layer per video bitrate

    for r = 1:numValid
        meanFrmSz(:,r) = find_mean_per_layer( Lengths(:,r), vs.f * vs.ipr, vs.L ); % BE CAREFUL!!!!!
    end

    meanFrmSz = meanFrmSz./repmat(meanFrmSz(1,:),vs.L+1,1); % mean P-frame length/mean I-frame length
    meanFrmSz(1,:) = [];

    model = fit([1000*fliplr(2.^(0:vs.L-1))/vs.f, 0]', [mean(meanFrmSz,2); 0],...
        fittype('fitmodel( x, a, b )'), 'Startpoint', [0 0]);

    vs.theta = model.a;
    vs.eta = model.b;  
    
%     fprintf('For f=%f Hz, theta=%f, eta=%f\n', vs.f, vs.theta,  vs.eta);
    
return

function k = estimFrameSz( vs, R )
% estimFrameSz      estimate the sizes of the I and P frames in the
% intra-period given the target encoding bitrate
%  Size of the P-frame tau ms apart from its reference normalized wrt the
%  I-frame is estimated using the model: | zhat | = 1 - exp(-theta*tau^-eta)
%  

    f = vs.f;
    L = vs.L;
    N = vs.N; % number of frames in intra-period
    B = 1000 * vs.ipr * R/8; % byte budget in intra-period
    
    zhatNorm = fliplr( 1-exp(-vs.theta*(1000*(2.^(0:L-1))./f).^vs.eta) );

    % n: number of P-frames in intra-period per TL, e.g. [7 8 16]
    n = fliplr( N ./ (2.^[ 1:L-1, L-1]) );
    n(1) = n(1)-1;

    zhat = (B(:)/(1 + n*zhatNorm')*[1, zhatNorm])';

    % find frame indices for each TL and create the k vector or matrix
    % start from the last layer, then previous, ...
    k = zeros(N,length(B));
    for r = 1:length(B)
        for layer = L : -1 : 1   
            k(mod(0:N-1,2^(L-layer))==0,r) = zhat(layer+1,r);
        end
    end
    k(1,:) = zhat(1,:);
return

function mean_x = find_mean_per_layer( x, N, L )
% find_mean_per_layer       groups the x vector according to the
% intra-period structure
%  This function creates cells for each layer + I frames. Then, the entries
%  of the x vector are put inside the corresponding cells. 

mean_x = cell(1,L+1); % put frame sizes per each layer in their corresponding cell

% P-frames from enhancement layers
for l = L : -1 : 2
    mean_x{ l+1 } = x(2 : 2 : end);
    x(2 : 2 : end) = [];
end

% I-frames
mean_x{1} = x(1 : N*2^(1-L) : end);
x(1 : N*2^(1-L) : end) = [];

% P-frames from base layer
mean_x{2} = x;

mean_x = (cellfun(@mean, mean_x))';

return