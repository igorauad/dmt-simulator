%% DMT Equalization Analysis through Monte-Carlo Simulation
clearvars, clc
addpath(genpath('../lib'))

%% Debug levels
debug               = 1;  % Enable debug information
debug_constellation = 0;  % Debug a certain subchannel constellation
debug_tone          = 16; % Tone whose constellation is debugged
debug_Pe            = 1;  % Debug error probabilities
debug_loading       = 0;  % Debug bit loading
debug_tx_energy     = 0;  % Debug transmit energy
debug_teq           = 0;  % Debug TEQ design

%% Parameters
alpha      = 1;         % Increase FFT size by this factor preserving Fs
% Note: this is useful to evaluate the DMT performance as N -> infty
L          = 1;         % Oversampling (support only for integer values)
Px         = 1e-3;      % Transmit Power (W)
N0_over_2  = 1e-10;     % Noise PSD (W/Hz/dim) and variance per dimension
N          = 128;       % FFT size and the number of used real dimensions
nu         = 8;         % Cyclic Prefix Length
tau        = 8;         % Cyclic Suffix
windowing  = 0;         % Activate Lcs windowing + Overlap
nDim       = N + nu;    % Total number of real dimensions per DMT symbol
gap_db     = 8.8;       % SNR gap to capacity (dB)
delta_f    = 51.75e3;   % Subchannel bandwidth
nSymbols   = 1e3;       % Number of DMT symbols per transmission iteration
max_load   = inf;        % Maximum allowed bit load for each subchannel
equalizer  = 0;         % 0 - None; 1) TEQ; 2) Cheong; 3) Time Domain
noDcNyquist= 1;         % Flag to avoid loading DC and Nyquist subchannels
% MMSE-TEQ Parameters
teqType    = 0;         % 0 - MMSE; 1 - SSNR; 2 - GeoSNR
% Monte-Carlo Parameters
maxNumErrs   = 100;
maxNumDmtSym = 1e12;

%% Derived computations:

% Number of used real dimensions and tone spacing adjusted by alpha
N         = N*alpha;
delta_f   = delta_f/alpha;
% Fs does not change with alpha.

% Sampling frequency and FFT size, based on the oversampling ratio:
Nfft      = L * N;
Fs        = Nfft * delta_f;
% delta_f does not change with L.

% Total number of real dimensions per DMT symbol
nDim       = Nfft + nu;

% Note the difference between alpha and L. Variable "alpha" is used to
% increase the density of the channel partitioning, namely reduce the tone
% spacing solely by increasing the number of used dimensions, while
% preserving the sampling frequency. In contrast, "L", the oversampling
% ratio, is used to increase the sampling frequency without altering the
% number of used dimensions, but only the FFT size. The latter naturally
% has to change according to "L" because the tone spacing must be
% preserved.

Ts        = 1 / Fs;
gap       = 10^(gap_db/10); % Gap in linear scale
Tofdm     = 1 / delta_f;    % OFDM symbol duration (without CP)
Tsym      = Tofdm + nu*Ts;  % Cyclic-prefixed multicarrier symbol period
Rsym      = 1 / Tsym;       % DMT Symbol rate (real dimensions per sec)
Ex        = Px * Tsym;      % Average DMT symbol energy
% Due to repetition of samples in the prefix, the energy budget is not
% entirely used for data transmission. Hence, the water-fill contraint must
% be designed as the energy budget discounted by the energy allocated to
% the cylic prefix. By setting the contraint to Ex*(Nfft/(Nfft + nu)), the
% effective transmit energy in the end is equal to Ex, as desired.
Ex_budget = Ex*(Nfft/(Nfft + nu)); % Energy budget passed to the WaterFill
Ex_bar    = Ex / nDim;      % Energy per real dimension

%% Constants
POST_PRE_ICPD_FLAG = 0;

% TEQ criterion
TEQ_MMSE    = 0;
TEQ_SSNR    = 1;

% Time-domain Precoder
tdPrecoderPostCursor = 0;
tdPrecoderPostPreCursor = 1;

% Normalized FFT Matrix
Q = (1/sqrt(Nfft))*fft(eye(Nfft));

%% Store vectors to look-up the number of dimensions in a subchannel
% subchannel_index_herm -> Contains the indexes that can be used as
%                          subchannels from the full Hermitian DFT.
%                          Bit loading will determine whether used or not.
% subchannel_index      -> Contains the indexes that can be used as
%                          subchannels from the positive half of the DFT.
%                          Again, bitloading determines wether used.

% Number of real dimensions in each tone of the DFT:
dim_per_dft_tone = [1 2*ones(1, Nfft/2-1) 1 2*ones(1, Nfft/2-1)];

% Vector of used subchannels among the DFT indices
% Assume DC is at tone 1 and Nyquist at Nfft/2 + 1. To compute the
% Hermitian symmetric of the k-th tone, we compute "Nfft + 2 - k".
if (L == 1)
    if (noDcNyquist)
        subCh_tone_index_herm = [2:(N/2), (Nfft +2 - N/2):Nfft].';
        subCh_tone_index      = 2:(N/2);
    else
        subCh_tone_index_herm = [1:(N/2 +1), (Nfft +2 - N/2):Nfft].';
        subCh_tone_index      = 1:(N/2 +1);
    end
else
    % When oversampling is used, it is easier to force the disabling of DC
    % and Nyquist tones. In this case, the bin that for L=1 (no
    % oversampling) represents Nyquist is loaded as a complex subchannel.
    warning('DC and Nyquist are tones are not loaded due to oversampling');
    noDcNyquist = 1;
    subCh_tone_index_herm = [2:(N/2 + 1), (Nfft +2 - N/2 - 1):Nfft].';
    % N/2 complex subcarriers at the positive half and the corresponding
    % N/2 complex conjugate subcarriers at the negative half.
    subCh_tone_index      = 2:(N/2 + 1);
end

% Then store the number of dimensions corresponding to each used subchannel
dim_per_subchannel   = dim_per_dft_tone(subCh_tone_index);

% Number of available subchannels
N_subch  = length(subCh_tone_index);

%% Pulse Response

channelChoice = 2;

switch (channelChoice)
    case 0
        p = [-.729 .81 -.9 2 .9 .81 .729];
        % Note: According to the model developed in Chap4 of EE379, p(t),
        % the pulse response, corresponds to the combination between the
        % post-DAC filter, the channel impulse response and the pre-ADC
        % filtering.
    case 1
        % D2-H2
        N_old = N;
        load('/Users/igorfreire/Documents/Lasse/gfast_simulator/Channel_Model/data/all_models_106mhz.mat');
        N = N_old;
        iModel = 2;
        H_herm = [H(:,iModel,iModel); conj(flipud(H(2:end-1,iModel,iModel)))];
        if (any(imag(ifft(H_herm, N)) > 1e-8))
            warning('H is not Hermitian symmetric');
        end
        clear H
        h = real(ifft(H_herm));

        p = truncateCir(h).';
    case 2
        % D2-H1
        load('/Users/igorfreire/Documents/Lasse/gfast_simulator/Cables/D2-H1.mat');
        h = real(ifft(H));

        if (any(imag(ifft(H, N)) > 0))
            warning('H is not Hermitian symmetric');
        end

        p = truncateCir(h).';
    case 3
        p = [1e-5 1e-5 .91 -.3 .2 .09 .081 .0729];
end

if (length(p) > Nfft)
    warning('Pulse response longer than Nfft');
end

% Pulse response length
Lh = length(p);

% Matched-filter Bound
SNRmfb = (Ex_bar * norm(p).^2) / N0_over_2;
fprintf('SNRmfb:    \t %g dB\n\n', 10*log10(SNRmfb))

%% Windowing

if (windowing)
    dmtWindow = designDmtWindow(Nfft, nu, tau);
else
    % When windowing is not used, the suffix must be 0
    tau = 0;
end

%% Equalizers
% The TEQ is designed before loading, by assuming flat input spectrum.
% However, since bit loading alters the energy allocation among
% subchannels, the TEQ is redesigned after bit loading.

switch (equalizer)
    case 1

fprintf('\n-------------------- MMSE-TEQ Design ------------------- \n\n');

        if (nu >= (Lh - 1))
            error('MMSE-TEQ is unecessary. CP is already sufficient!');
        end

        % Search optimum length and delay for the TEQ design
        [nTaps, delta] = optimizeTeq(teqType, p, nu, L, N0_over_2, ...
            Ex_bar, Nfft, debug_teq);
        fprintf('Optimal Equalizer Length:\t %d\n', nTaps);
        fprintf('Optimal Delay:           \t %d\n', delta);

        % Design final TEQ
        switch (teqType)
            case TEQ_MMSE
                [w, SNRteq] = ...
                    mmse_teq(p, L, delta, floor(nTaps/L), nu, Ex_bar, ...
                    N0_over_2, debug_teq);
                fprintf('New SNRmfb (TEQ):\t %g dB\n', 10*log10(SNRteq))
            case TEQ_SSNR
                w = ssnr_teq(p, L, delta, floor(nTaps/L), nu, debug_teq);
        end

        if(~isreal(w))
            warning('MMSE-TEQ designed with complex taps');
        end

        % Shortening SNR:
        ssnr_w = ssnr( w, p, delta, nu );
        fprintf('SSNR:\t %g dB\n', 10*log10(ssnr_w));
    case 2
fprintf('\n------------------- Freq DMT Precoder ------------------ \n');
        FreqPrecoder = dmtFreqPrecoder(p, N, nu, tau, n0, windowing);
        w_norm_n =  FreqPrecoder.wk;
    case 3
fprintf('\n------------------- Time DMT Precoder ------------------ \n\n');
        TimePrecoder = dmtTimePrecoder(p, n0, nu, tau, N,...
            tdPrecoderPostCursor, windowing);
        w_norm_n =  TimePrecoder.ici.wk;
end

%% Effective pulse response

switch (equalizer)
    case 1
        % New effective channel:
        p_eff = conv(p,w);
    otherwise
        p_eff = p;
end

%% Channel Frequency Response

% Frequency domain response (use the effective pulse response in the FEQ)
H = fft(p_eff, Nfft);

% Store only the response at the used indices of the FFT
Hn = H(subCh_tone_index_herm);

%% Cursor
switch (equalizer)
    case 1
        % MMSE-TEQ Chosen Delay
        n0 = delta;
        % The cursor considers the MMSE-TEQ delay.
    otherwise
        [~, iMax] = max(abs(p));
        n0 = iMax - 1;
end

% Corresponding phase shift due to cursor
phaseShift = exp(1j*2*pi*(n0/Nfft)*(subCh_tone_index_herm.' - 1));

%% Frequency Equalizer
FEQn    = (1 ./ (Hn .* phaseShift));

%% ICPD PSD
% Compute the ICPD PSD, which is considered in the ensuing computation of
% the bit loading.
%
% Note: for the frequency and time-domain ICPD precoders (which should
% fully cancel the ICPD), the ICPD is considered null.

if (equalizer == 2 || equalizer == 3)
    S_icpd = zeros(Nfft, 1);
else
    S_icpd = icpdPsd(p_eff, Nfft, Nfft, nu, tau, n0, Ex_bar, windowing);
end

%% Gain-to-noise Ratio

switch (equalizer)
    case 1
        % Notes:
        %   # 1) The water-filling solution assumes no ISI/ICI. Even though
        %   the TEQ constrains the pulse response energy to a portion that
        %   can be covered by the guard band (commonly referred to the
        %   "window" of the SIR), the out-of-window response of the
        %   shortened response may still be significant and introduce
        %   non-negligible ISI/ICI.
        %   # 2) Note the feed-foward TEQ at the receiver shapes the
        %   spectrum of the noise, so the noise PSD becomes |H_w|^2 * N0/2,
        %   where H_w is given below:
        H_w = fft(w, Nfft);
        %   # 3) Meanwhile, the transmit signal is subject to the
        %   compounded response of the channel + equalizer, namely the
        %   effective response:
        H_eff = fft(p_eff, Nfft);
        %   # 4) Then, assuming that the ICPD is uncorrelated to the noise,
        %   the gain to noise ratio at the receiver becomes:
        gn = (abs(H_eff).^2)./((N0_over_2 * abs(H_w).^2) + S_icpd.');
        %   Store only the used tones
        gn = gn(subCh_tone_index_herm);
        %   Note that if ICPD was not accounted, since H_eff = Hn .* H_w,
        %   the above gain-to-noise ratio would tend to be equivalent to
        %   (for all non-zero H_W):
        %       gn = (abs(Hn).^2) / N0_over_2;
        %   Ultimately, the gain-to-noise ratio is not being affected by
        %   the TEQ in the expression. This can be the fallacious in the
        %   model.
    case 2
        % The energy increase in each subchannel is given by the Euclidean
        % norm of the corresponding row. Thus, the total energy after
        % precoding becomes, on average, sum(Ex_bar_n * w_norm_n), for n in
        % 0 to N-1. Assuming an initial flat energy load among subchannels,
        % i.e., that Ex_bar_n is the same for all n, then the total average
        % tx energy is Ex = Ex_bar * sum(w_norm_n), so that the resulting
        % energy per dimension becomes Ex_bar * sum(w_norm_n) / N. From
        % that, we can conclude that the energy per dimension is increased
        % through precoding by a factor of "sum(w_norm_n)/N" or,
        % equivalently, by mean(w_norm_n). This increase must be
        % compensated in the budget passed to the water-filling solver.
        % Furthermore, note that water-fill does not lead to flat energy
        % load, so that better results can be obtained by jointly designing
        % the energy budget scale factor and the bit loading.
        gn = (abs(Hn).^2) ./ (w_norm_n * N0_over_2);
    case 3
        % The normalization adopted for the time-domain precoder is almost
        % equal to the one for the frequency-domain precoder. The only
        % difference is that the entries zeroed for complexity reduction
        % are accounted.
        gn = (abs(Hn).^2) ./ (w_norm_n * N0_over_2);
    otherwise
        gn = (abs(Hn).^2) ./ (N0_over_2 + S_icpd(subCh_tone_index_herm).');
end

%% Water filling

fprintf('\n--------------------- Water Filling -------------------- \n\n');

% Water-filling:
[bn_bar, En_bar] = waterFilling(gn, Ex_budget, N, gap);

% Residual unallocated energy
fprintf('Unallocated energy:      \t  %g\n', Ex_budget - sum(En_bar));

% Bits per subchannel
bn = bn_bar(1:N_subch) .* dim_per_subchannel;
% Number of bits per dimension
b_bar = (1/nDim)*(sum(bn_bar));
fprintf('b_bar:                  \t %g bits/dimension\n', b_bar)
% For gap=0 and N->+infty, this should be the channel capacity per real
% dimension.

% Corresponding multi-channel SNR:
SNRdmt = 10*log10(gap*(2^(2*b_bar)-1));
% SNR at each tone, per dimension:
SNR_n = En_bar .* gn;
% Normalized SNR on each tone, per dimension (should approach the target
% gap):
SNR_n_norm = SNR_n ./ (2.^(2*bn_bar) - 1);

fprintf('Multi-channel SNR (SNRdmt):\t %g dB\n', SNRdmt)

if (equalizer == 1)
    fprintf('Note: shortened response was used for water-filling.\n');
end

%% Discrete-loading: Levin Campello Rate Adaptive

fprintf('\n------------------ Discrete Loading -------------------- \n\n');

% Rate-adaptive Levin-Campello loading:
[En_discrete, bn_discrete] = DMTLCra(...
    gn(1:N_subch),...
    Ex_budget,...
    N, gap_db, ...
    max_load, ...
    dim_per_subchannel);

% Residual unallocated energy
fprintf('Unallocated energy:      \t %g\n', Ex_budget - sum(En_discrete));

% Save a vector with the index of the subchannels that are loaded
n_loaded = subCh_tone_index(bn_discrete ~= 0);
% Number of subchannels that are loaded
N_loaded = length(n_loaded);
% Dimensions in each loaded subchannel
dim_per_loaded_subchannel = dim_per_dft_tone(n_loaded);

% Energy per real dimension
En_bar_lc = En_discrete ./ dim_per_subchannel;
% Bits per subchannel per dimension
bn_bar_lc = bn_discrete ./ dim_per_subchannel;

% Total bits per dimension:
b_bar_discrete = 1/nDim*(sum(bn_discrete));

% SNRdmt from the number of bits per dimension
SNRdmt_discrete    = gap*(2^(2*b_bar_discrete)-1);
SNRdmt_discrete_db = 10*log10(SNRdmt_discrete);
% SNR on each tone, per real dimension:
SNR_n_lc           = En_bar_lc .* gn(1:N_subch);
% Normalized SNR on each tone, per dimension (should approach the gap)
SNR_n_norm_lc      = SNR_n_lc ./ (2.^(2*bn_bar_lc) - 1);

% Bit rate
Rb = sum(bn_discrete) / Tsym;

fprintf('b_bar:                    \t %g bits/dimension', b_bar_discrete)
fprintf('\nBit rate:               \t %g mbps\n', Rb/1e6);
fprintf('Multi-channel SNR (SNRdmt): \t %g dB\n', ...
    SNRdmt_discrete_db);

% Compare water-filling and discrete-loading
if (debug && debug_loading)
    figure
    plot(subCh_tone_index, bn, ...
        'linewidth', 1.1)
    hold on
    plot(subCh_tone_index, bn_discrete, 'g')
    legend('Water-filling', 'Discrete Loading')
    xlabel('Subchannel');
    ylabel('Bits');
    grid on
    title('Bit loading')
end

%% Channel Capacity
% Channel capacity is computed considering the SNR that results from LC
% discrete loading.

fprintf('\n------------------ Channel Capacity -------------------- \n\n');

% Capacity per real dimension
cn_bar = 0.5 * log2(1 + SNR_n_lc);
% Capacity per subchannel
cn = cn_bar .* dim_per_subchannel;
% Multi-channel capacity, per dimension:
c = sum(cn) / nDim;
% Note #1: for the capacity computation, all real dimensions are
% considered, including the overhead. See the example of (4.208)
% Note #2: the actual capacity is only obtained for N -> infty, so the
% above is only an approximation.

fprintf('capacity:               \t %g bits/dimension', c)
fprintf('\nBit rate:               \t %g mbps\n', c * Rsym * nDim /1e6);

%% Analysis of the Error Probability per dimension
% Comparison between the water-filling and the discrete loading in terms of
% the nearest-neighbors union bound probability of error.

fprintf('\n----------------- Error Probabilities ------------------ \n\n');

% Water-filling:
Pe_bar_n    = dmtPe(bn, SNR_n, dim_per_subchannel);
% Levin-Campello:
Pe_bar_n_lc = dmtPe(bn_discrete, SNR_n_lc, dim_per_subchannel);


if (debug && debug_Pe)
    figure
    semilogy(n_loaded, Pe_bar_n, 'linewidth', 1.1)
    hold on
    semilogy(n_loaded, Pe_bar_n_lc, 'r')
    xlabel('Subchannel');
    ylabel('$\bar{P_e}$', 'Interpreter', 'latex')
    legend('Water-filling', 'Levin-Campello')
    title('Pe per dimension on each subchannel')
    grid on
end

% NNUB Pe per dimension:
Pe_bar    = mean(Pe_bar_n, 'omitnan');
Pe_bar_lc = mean(Pe_bar_n_lc, 'omitnan');

fprintf('Approximate NNUB Pe per dimension:\n');
fprintf('Fractional-load (WF):\t %g\n', mean(Pe_bar_n, 'omitnan'));
fprintf('Discrete-load (LC)  :\t %g\n', mean(Pe_bar_n_lc, 'omitnan'));

%% Modulators

% Modulation order on each subchannel
modOrder = 2.^bn_discrete;

[modulator, demodulator] = dmtGenerateModems(modOrder, dim_per_subchannel);

%% Look-up table for each subchannel indicating the corresponding modem

modem_n = dmtModemLookUpTable(modOrder, dim_per_subchannel);

%% Energy loading (constellation scaling factors) and minimum distances

[Scale_n, dmin_n] = dmtSubchanScaling(modulator, modem_n, ...
                    En_discrete, dim_per_subchannel);

%% Monte-carlo

fprintf('\n---------------------- Monte Carlo --------------------- \n\n');

% Preallocate
X          = zeros(Nfft, nSymbols);
tx_data    = zeros(N_loaded, nSymbols);
rx_data    = zeros(N_loaded, nSymbols);
sym_err_n  = zeros(N_loaded, 1);

numErrs = 0; numDmtSym = 0;

% Sys Objects
BitError = comm.ErrorRate;

%% Iterative Transmissions

iTransmission = 0;

while ((numErrs < maxNumErrs) && (numDmtSym < maxNumDmtSym))
    iTransmission = iTransmission + 1;

    % Random Symbol generation
    for k = 1:N_loaded
        tx_data(k, :) = randi(modOrder(k), 1, nSymbols) - 1;
    end

    %% Constellation Encoding
    for k = 1:N_loaded
        if (modem_n(k) > 0)
            X(n_loaded(k), :) = Scale_n(k) * ...
                modulator{modem_n(k)}.modulate(tx_data(k, :));
        end
    end

    % Hermitian symmetry
    X(Nfft/2 + 2:Nfft, :) = flipud( conj( X(2:Nfft/2, :) ) );

    %% Per-tone Precoder
    if (equalizer == 2)
        X = precodeFreqDomain( X, FreqPrecoder, modOrder, dmin_n );
    end

    x = sqrt(Nfft) * ifft(X, Nfft);

    if (equalizer == 3)
        x = precodeTimeDomain( x, TimePrecoder );
    end

    %% Cyclic extension -> Windowing + overlap -> Parallel to serial
    if (windowing)
        x_ext = [x(Nfft-nu+1:Nfft, :); x; x(1:tau,:)];
        x_ce = windowAndOverlap(x_ext, dmtWindow, Nfft, nu, tau);
        u = x_ce(:);
    else
        x_ext = [x(Nfft-nu+1:Nfft, :); x];
        u = x_ext(:);
    end

    %% Debug Tx Energy

    if (debug && debug_tx_energy)
        % Note: "u" should become samples leaving the DAC. In that case,
        % they would repreent coefficients of the sampling theorem's sinc
        % interpolation formula, which is an orthogonal (non-normal)
        % expansion. However, note x comes from an orthonormal expansion,
        % which is the normalized IDFT. Hence, the energy in x at this
        % point is still given simply by:
        tx_total_energy = norm(u).^2;

        % A Ts factor should multiply the norm if u was a vector of samples
        % out of the DAC, but in this case there would be a scaling factor
        % introduced by the DAC anti-imaging LPF. Both would cancel each
        % other.
        fprintf('Tx Energy p/ Sym:\t%g\t', ...
            tx_total_energy / nSymbols);
        % Nominal energy is the value designed considering the energy
        % allocated in the bit-loading algorithm plus the excess energy in
        % the prefix
        fprintf('Design value:\t%g\t', sum(En_discrete)*(Nfft + nu)/Nfft);
    end

    %% Channel

    y = conv(u, p);
    % Note:
    %   In contrast to the derivation of Chapter 3, here the scaling of Ts
    %   is not used. The reason is that "u" comes from an orthonormal
    %   expansion (the normalized IFFT) and p also satisfies the inner
    %   product invariance, due to the more involved explanation in the
    %   sequel.
    %
    %   The text mentions that "the notational use of P for the channel
    %   matrix suggests that any anti-alias analog filters at transmitter
    %   and receiver have been convolved with the channel impulse response
    %   h(t) and included in the discrete-time response of the matrix
    %   channel". The model is given in (4.185).
    %
    %   So let us further interpret that: once we have a measurement of the
    %   channel impulse response, we have samples and, therefore,
    %   coefficients of an orthogonal expansion. Thus, convolution or inner
    %   product (for energy computation) can not be applied directly,
    %   only with a Ts factor in front. Nonetheless, in practice the
    %   samples would be obtained by first passing the signal through an
    %   anti-alias LPF, ideally with unitary-energy. Such filter
    %   effectively scales each "pre-ADC" sample by sqrt(Ts). To understand
    %   that, note a unitary energy anti-alias filter has continuous-time
    %   response:
    %
    %       1/sqrt(Ts) * sinc(t/Ts)
    %
    %   Then, by sampling at t = kTs, the only non-zero value of the
    %   sampled sequence is "1/sqrt(Ts)". Finally, by convolving the
    %   "pre-ADC" samples (from an orthogonal expansion) with the receive
    %   filter samples, one obtains:
    %
    %       h = Ts * conv(rx_filter, h)
    %         = Ts * (1/sqrt(Ts)) * h
    %         = sqrt(Ts) * h_pre_adc
    %
    %   Essentially, when we sample the channel, we get h, instead of
    %   h_pre_adc. The channel impulse response energy can be computed by
    %   either "Ts * norm(h_pre_adc)^2" or "norm(h)^2", because both are
    %   equivalent. Similarly, the sampled response "h" can be used
    %   directly in the convolution, without a Ts factor in front.

    % Add noise
    noise = (sqrt(N0_over_2) * randn(length(y),1));
    y = y + noise;
    % Important considerations:
    %
    % First, recall the noise continuous-time PSD coincides with the noise
    % energy per dimension. Second, remember that the sinc functions in the
    % orthogonal expansion of the sampling theorem have energy 1/2W, so the
    % variance of each real and imaginary coefficient in the noise
    % expansion must be scaled up by 2W from the noise energy N0/2 per
    % degree of freedom. Since AWGN is flat, multiplication of N0/2
    % (two-sided PSD) by 2W yields the total transmit power. Hence, if "y"
    % consisted of samples, the target variance for the "randn" sequence
    % would be the noise power N0_over_2 * 2W. However, the catch here is
    % that y does not represent the samples

    %% Time-domain Equalization
    switch (equalizer)
        case 1
            z = conv(w, y);
        otherwise
            z = y;
    end

    %% Synchronization
    % Note: synchronization introduces a phase shift that should be taken
    % into account in the FEQ.

    nRxSamples = (Nfft+nu)*nSymbols;
    y_sync     = z((n0 + 1):(n0 + nRxSamples));

    %% Slicing

    y_sliced = reshape(y_sync, Nfft + nu, nSymbols);

    %% Extension removal

    y_no_ext = y_sliced(nu + 1:end, :);

    %% Frequency-domain Equalization
    switch (equalizer)
        case 3 % Time-domain ISI DFE
            % Note: the section name may be misleading. The receiver below
            % equalizes ISI using time-domain DMT symbols. However, its
            % derivation is based in the frequency-domain.
            [ rx_symbols, Z ] = dmtTdDfeReceiver(y_no_ext, modulator, ...
                demodulator, modem_n, Scale_n, TimePrecoder, FEQn);
        case 2 % DMT with additional modulo operation
            [ rx_symbols, Z ] = dmtFreqPrecReceiver(y_no_ext, demodulator, ...
                modem_n, Scale_n, FEQn, modOrder, dmin_n);
        otherwise
            % FFT
            Y = (1/sqrt(Nfft)) * fft(y_no_ext, Nfft);

            % FEQ - One-tap Frequency Equalizer
            Z = diag(FEQn) * Y(subCh_tone_index_herm, :);

            %% Constellation decoding (decision)
            for k = 1:N_loaded
                if (modem_n(k) > 0)
                    rx_data(k, :) = demodulator{modem_n(k)}.demodulate(...
                        (1/Scale_n(k)) * Z(k, :));
                end
            end
    end

    %% Error results

    % Symbol error count
    sym_err_n = sym_err_n + symerr(tx_data, rx_data, 'row-wise');
    % Symbol error rate per subchannel
    ser_n     = sym_err_n / (iTransmission * nSymbols);
    % Per-dimensional symbol error rate per subchannel
    ser_n_bar = ser_n ./ dim_per_loaded_subchannel.';

    % Preliminary results
    numErrs   = sum(sym_err_n);
    numDmtSym = iTransmission * nSymbols;

    fprintf('Pe_bar:\t%g\t', mean(ser_n_bar));
    % Note: consider only the loaded subchannels in the above
    fprintf('nErrors:\t%g\t', numErrs);
    fprintf('nDMTSymbols:\t%g\n', numDmtSym);

    %% Re-training of the bit-loading
    % The initial bit-loading can often be innacurate, mostly due to the
    % ICPD that is initially computed assuming the input is perfectly
    % uncorrelated. During show-time, we can compute the actual correlation
    % of the transmit signal and use it to compute a more accurate ICPD
    % PSD. Using this PSD, in turn, we update the bit-load and restart the
    % transmission.

    % If the error is too high, bit-loading shall be re-trained
    if (mean(ser_n_bar) > 10 * Pe_bar_lc)
        fprintf('\n## Re-training the ICPD PSD and the bit-load vector...\n');

        % Compute the ISI matrices
        [Hisi, ~, ~, HpreIsi, ~] = ...
            dmtIsiIciMatrices(p_eff, n0, nu, tau, Nfft, windowing);
        % Input Autocorrelation based on actual transmit data
        [r, l] = xcorr(x(:), Nfft-1, 'unbiased');
        % Autocorrelation Matrix
        Rxx = toeplitz(r(Nfft:end));
        % Update the ICPD based on the ISI Matrices and the autocorrelation
        % matrix
        S_icpd = icpdPsdMtx(Hisi, HpreIsi, Rxx, Nfft);

        % Update the gain-to-noise ratio:
        switch (equalizer)
            case 1
                gn = (abs(H_eff).^2)./((N0_over_2 * abs(H_w).^2) + S_icpd.');
                gn = gn(subCh_tone_index_herm);
            case 0
                gn = (abs(Hn).^2) ./ (N0_over_2 + S_icpd(subCh_tone_index_herm).');
        end

        % Rate-adaptive Levin-Campello loading:
        [En_discrete, bn_discrete] = DMTLCra(...
            gn(1:N_subch),...
            Ex_budget,...
            N, gap_db, ...
            max_load, ...
            dim_per_subchannel);

        % Save a vector with the index of the subchannels that are loaded
        n_loaded = subCh_tone_index(bn_discrete ~= 0);
        % Number of subchannels that are loaded
        N_loaded = length(n_loaded);
        % Dimensions in each loaded subchannel
        dim_per_loaded_subchannel = dim_per_dft_tone(n_loaded);

        % Total bits per dimension:
        b_bar_discrete = 1/nDim*(sum(bn_discrete));
        % Bit rate
        Rb = sum(bn_discrete) / Tsym;

        % Print the results of the new bit-load
        fprintf('b_bar:     \t %g bits/dimension', b_bar_discrete)
        fprintf('\nBit rate:\t %g mbps\n', Rb/1e6);
        fprintf('## Restarting transmission...\n\n');

        % Update the vector of modulation orders
        modOrder = 2.^bn_discrete;
        % Update modem objects
        [modulator, demodulator] = dmtGenerateModems(modOrder, dim_per_subchannel);
        % Re-generate modem look-up table
        modem_n = dmtModemLookUpTable(modOrder, dim_per_subchannel);
        % Re-generate the subchannel scaling factors
        [Scale_n, dmin_n] = dmtSubchanScaling(modulator, modem_n, ...
            En_discrete, dim_per_subchannel);

        % Finally, reset the SER computation:
        sym_err_n  = zeros(N_loaded, 1);
        numErrs = 0; numDmtSym = 0; iTransmission = 0;
    end

    %% Constellation plot for debugging
    if (debug && debug_constellation && modem_n(debug_tone) > 0 ...
        && iTransmission == 1)
        k = debug_tone;

        viewConstellation(Z, Scale_n(k) * ...
                modulator{modem_n(k)}.modulate(0:modOrder(k) - 1), k);
    end

end

%% Results
fprintf('\n----------------------- Results ------------------------ \n\n');
fprintf('Pe_bar:       \t %g\n', mean(ser_n_bar));

if (debug && debug_Pe)
    figure
    stem(ser_n_bar)
    hold on
    stem(Pe_bar_n, 'g')
    hold on
    stem(Pe_bar_n_lc, 'r')
    title('Results: Pe per dimension')
    xlabel('Subchannel (n)')
    ylabel('$\bar{Pe}(n)$')
    legend('Measured','WF','LC')
end
