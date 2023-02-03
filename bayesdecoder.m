function [P_cX,P_Xc,pthat,features,P_X] = bayesdecoder(tensor,opt)
    %UNTITLED Summary of this function goes here
    %   Detailed explanation goes here

    %% input parsing
    [n_classes,n_features,~] = size(tensor);

    %% output preallocation
    features = cell(n_features,1);
    for ff = 1 : n_features
        features{ff} = struct();
    end
    features = cell2mat(features);
    X_mus = nan(n_classes,n_features);
    P_Xc = nan(n_classes,n_features,opt.n_xpoints);
    P_cX = nan(n_classes,n_classes,opt.test.n_trials);
    P_X = nan(n_classes,n_features,opt.n_xpoints);
    pthat.mode = nan(n_classes,opt.test.n_trials);
    pthat.median = nan(n_classes,opt.test.n_trials);
    pthat.mean = nan(n_classes,opt.test.n_trials);

    %% overwrite MATLAB's builtin definition for the poisson PDF
    poisspdf = @(lambda,k) ...
        exp(k .* log(lambda + 1e-100) - lambda - gammaln(k + 1));

    %% estimate feature spans

    % iterate through features
    for ff = 1 : n_features
        if opt.verbose
            progressreport(ff,n_features,'estimating feature spans');
        end

        % parse feature
        X = squeeze(tensor(:,ff,:));

        % estimate feature span
        x_bounds = quantile(X(:),[0,1]+[1,-1]*.001).*(1+[-1,1]*.025);
        [~,x_edges] = histcounts(X(X>=x_bounds(1)&X<=x_bounds(2)),opt.n_xpoints);

        % update feature
        features(ff).idx = ff;
        features(ff).x_bounds = x_bounds;
        features(ff).x_edges = x_edges;
        features(ff).x_bw = range(x_bounds) / 10;
    end

    %% construct encoding models

    % iterate through features
    for ff = 1 : n_features
        if opt.verbose
            progressreport(ff,n_features,'constructing encoding models');
        end

        % parse feature
        X = squeeze(tensor(:,ff,:));
        x_bounds = features(ff).x_bounds;
        x_edges = features(ff).x_edges;
        x_bw = features(ff).x_bw;

        % compute tuning function
        X_mus(:,ff) = nanmean(X(:,opt.train.trial_idcs),2);

        % kernel definition
        x_kernel = normpdf(x_edges,mean(x_bounds),x_bw);
        x_kernel = x_kernel / nansum(x_kernel);

        % compute joint distribution
        if opt.assumepoissonmdl

            % store theoretical joint distribution
            P_Xc(:,ff,:) = poisspdf(X_mus(:,ff),x_edges(1:end-1));
        else

            % preallocation
            p_Xc = nan(n_classes,opt.train.n_trials,opt.n_xpoints);
            p_X = nan(n_classes,opt.train.n_trials,opt.n_xpoints);

            % iterate through training trials
            for kk = 1 : opt.train.n_trials
                train_idx = opt.train.trial_idcs(kk);

                % compute likelihood
                Xc_counts = histcounts2(1:n_classes,X(:,train_idx)',...
                    'xbinedges',1:n_classes+1,...
                    'ybinedges',x_edges);
                p_Xc(:,kk,:) = conv2(x_kernel,x_kernel,Xc_counts,'same');

                %
                x_counts = histcounts(X(:,train_idx),...
                    'binedges',x_edges);
                p_X(:,kk,:) = repmat(...
                    conv2(1,x_kernel,x_counts,'same'),n_classes,1);
            end

            % store average empirical joint distribution
            P_Xc(:,ff,:) = nanmean(p_Xc,2);

            %
            P_X(:,ff,:) = nanmean(p_X,2);
        end

        % normalization
        P_Xc(:,ff,:) = P_Xc(:,ff,:) ./ nansum(P_Xc(:,ff,:),3);
        P_X(:,ff,:) = P_X(:,ff,:) ./ nansum(P_X(:,ff,:),3);

        % update feature
        features(ff).x_mu = X_mus(:,ff);
        features(ff).p_Xc = squeeze(P_Xc(:,ff,:));
        features(ff).p_X = squeeze(P_Xc(1,ff,:));
    end

    %% construct posteriors

    % prior definition
    p_c = ones(n_classes,1) / n_classes;

    % iterate through test trials
    for kk = 1 : opt.test.n_trials
        if opt.verbose
            progressreport(kk,opt.test.n_trials,'constructing posteriors');
        end

        %
        test_idx = opt.test.trial_idcs(kk);

        % iterate through classes for the current test trial
        for cc = 1 : n_classes

            % fetch current observations
            x = tensor(cc,:,test_idx)';
            if all(isnan(x))
                continue;
            end

            % compute likelihoods of the current observations
            if opt.assumepoissonmdl

                % assume a features are poisson-distributed
                p_cx = poisspdf(X_mus',round(x));
            else

                % index current observation
                x_edges = vertcat(features.x_edges);
                [~,x_idcs] = min(abs(x_edges(:,1:end-1) - x),[],2);

                % preallocation
                p_cx = nan(n_features,n_classes);
                p_x = nan(n_features,n_classes);

                % iterate through features
                rand_idcs = randperm(n_classes);
                for ff = 1 : n_features

                    % assume empirical encoding model
                    p_cx(ff,:) = P_Xc(:,ff,x_idcs(ff));

                    p_x(ff,:) = P_X(:,ff,x_idcs(ff));
                end
            end

            if opt.subtractchance
                p_cx = p_cx - p_x;
            end

            % normalization
            p_cx = p_cx ./ nansum(p_cx,2);
            p_x = p_x ./ nansum(p_x,2);
            nan_flags = all(isnan(p_cx),2) | isnan(x);
            if all(nan_flags)
                continue;
            end

            % compute posterior (accounting for numerical precision issues)
            fudge = 1 + 1 / n_features;
            p_cX = p_c .* prod(p_cx(~nan_flags,:) * n_classes + fudge,1)';

            % normalization
            p_X = nansum(p_cX);
            P_cX(cc,:,kk) = p_cX / p_X;
        end

        % flag valid time for the current trial
        test_time_flags = ~all(isnan(P_cX(:,:,kk)),2);

        % fetch single trial posteriors to compute point estimates
        P_cX_kk = P_cX(test_time_flags,:,kk);

        % posterior mode (aka MAP)
        [~,mode_idcs] = max(P_cX_kk,[],2);
        pthat.mode(test_time_flags,kk) = opt.classes(mode_idcs);

        % posterior median
        median_flags = [false(sum(test_time_flags),1),...
            diff(cumsum(P_cX_kk,2) > .5,1,2) == 1];
        [~,median_idcs] = max(median_flags,[],2);
        pthat.median(test_time_flags,kk) = opt.classes(median_idcs);

        % posterior mean (aka COM)
        P_cX_kk(isnan(P_cX_kk)) = 0;
        pthat.mean(test_time_flags,kk) = opt.classes * P_cX_kk';
    end
end

%% utility functions
function progressreport(iter,n_iter,message,bar_len)
    if nargin < 4
        bar_len = 30;
    end
    persistent progress;
    if isempty(progress)
        progress = -1;
    elseif progress ~= floor(iter / n_iter * 100)
        progress = floor(iter / n_iter * 100);
    else
        return;
    end
    if iter > 1
        for jj = 1 : (length(message) + bar_len + 8)
            fprintf('\b');
        end
    end
    fprintf('|');
    for jj = 1 : bar_len
        if progress/(100/bar_len) >= jj
            fprintf('#');
        else
            fprintf('-');
        end
    end
    fprintf('| ');
    if progress == 100
        fprintf([message, ' ... done.\n']);
    else
        fprintf([message, ' ... ']);
    end
end
