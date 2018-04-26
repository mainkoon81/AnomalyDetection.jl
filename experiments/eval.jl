using DataFrames, Query, FileIO, ValueHistories
import Missings: missing, skipmissing, ismissing

push!(LOAD_PATH, "../src")
using AnomalyDetection

"""
    auroc(ascore, labels)

Compute area under ROC curve. If ascores are NaNs, returns value.
"""
function auroc(ascore, labels)
    if isnan(ascore[1])
        return missing
    else
        tprvec, fprvec = AnomalyDetection.getroccurve(ascore, labels)
        return AnomalyDetection.auc(fprvec, tprvec)
    end
end

"""
    topprecision(ascore, labels, p)

Computes precision in prediction based on top p% rated instances.
"""
function topprecision(ascore, labels, p)
    if isnan(ascore[1])
        return missing
    else
        N = size(ascore,1)
        @assert size(labels,1) == N
        topN = Int(round(N*p))
        si = 1:topN
        isort = sortperm(ascore, rev = true)
        sl = labels[isort][si]
        return sum(sl)/sum(labels[end-topN+1:end]) # precision = true positives/labeled positives
    end
end

"""
    computedatasetstats(datapath, dataset, algnames)

Compute comprehensive stats for a single dataset and all experiments that were run on it.
Returns a DataFrame containing training and testing auroc, top 5% precision
and fit/predict time.
"""
function computedatasetstats(datapath, dataset, algnames)
    df = DataFrame()
    cnames = ["dataset", "algorithm", "iteration", "settings", "train_auroc", "test_auroc", 
        "top_5p", "fit_time", "predict_time"]
    for name in cnames
        df[Symbol(name)] = Any[]
    end
    
    path = joinpath(datapath, dataset)
    algs = readdir(path)
    for alg in intersect(algs, algnames)
        _path = joinpath(path, alg)
        iters = readdir(_path)
        for iter in iters
            __path = joinpath(_path, iter)
            ios = readdir(__path)
            for io in ios
                f = joinpath(__path, io)
                # compute training and testing auroc
                trauroc = auroc(load(f, "training_anomaly_score"), load(f, "training_labels"))
                tstauroc = auroc(load(f, "testing_anomaly_score"), load(f, "testing_labels"))
                
                # compute top 5% ascore samples precision
                tp = topprecision(load(f, "training_anomaly_score"), load(f, "training_labels"), 0.05)
                
                # extract the times as well
                ft = load(f, "fit_time")
                pt = load(f, "predict_time")

                # save the data
                push!(df, [dataset, alg, iter, io, trauroc, tstauroc, tp, ft, pt])
            end
        end
    end

    return df
end

"""
    computestats(datapath, algnames)

Gather comprehensive statistics for all datasets in a single dataframe.
"""
function computestats(datapath, algnames)
    df = DataFrame()
    cnames = ["dataset", "algorithm", "iteration", "settings", "train_auroc", "test_auroc", 
        "top_5p", "fit_time", "predict_time"]
    for name in cnames
        df[Symbol(name)] = Any[]
    end
    
    datasets = readdir(datapath)

    for dataset in datasets
        df = [df; computedatasetstats(datapath, dataset, algnames)]
    end
    
    return df
end

"""
    loadtable(fname, datacols)

Load a csv file into DataFrame, reformatting specified data columnsto floats and missings.
"""
function loadtable(fname, datacols)
    #load the df
    data = readtable(fname)
    
    for cname in names(data)
        data[cname] = Array{Any,1}(data[cname])
    end
    
    nrows, ncols = size(data)
    
    # go through the whole df and replace missing strings with actual Missing type
    # and floats with float
    for cname in names(data)[datacols]
        for i in 1:nrows
            (data[cname][i] == "missing")? data[cname][i]=missing : 
                data[cname][i]=round(float(data[cname][i]),6)
        end
    end
    
    return data
end

"""
    rankdf(df, [rev])

Compute row ranks for a DataFrame and add bottom line with mean ranks.
Ties receive average rank.
rev (default true) - higher score is better 
"""
function rankdf(df, rev = true)
    _df = deepcopy(df)
    nrows, ncols = size(_df)
    nalgs = ncols - 1
    
    algnames = names(df)[2:end]
    
    for i in 1:nrows
        row = _df[i,2:end]
        arow = reshape(Array(row), nalgs)
        isort = sortperm(arow, rev = rev)
        j = 1    
        tiec = 0 # tie counter
        # create ranks
        arow = collect(skipmissing(arow))
        for alg in algnames[isort]
            if ismissing(row[alg][1])
                _df[alg][i] = missing
            else
                # this decides ties
                val = row[alg][1]
                nties = size(arow[arow.==val],1) - 1
                if nties > 0
                    _df[alg][i] = (sum((j-tiec):(j+nties-tiec)))/(nties+1)
                    tiec +=1
                    # restart tie counter
                    if tiec > nties
                        tiec = 0
                    end
                else
                    _df[alg][i] = j
                end
                j+=1  
            end
        end
    end
    
    # append the final row with mean ranks
    push!(_df, cat(1,Array{Any}(["mean rank"]), zeros(nalgs)))
    for alg in algnames
        _df[alg][end] = missmean(collect(skipmissing(_df[alg][1:end-1])))
    end
    
    return _df
end

"""
    missmean(x)

If x is empty, return missing, else compute mean.
"""
function missmean(x)
    if size(x,1) == 0
        return missing
    else
        return(mean(x))
    end
end

"""
    missmax(x)

If x is empty, return missing, else return maximum.
"""
function missmax(x)
    if size(x,1) == 0
        return missing
    else
        return(maximum(x))
    end
end

"""
    missfindmax(x)

If x is empty, return missing, else return maximum and its indice.
"""
function missfindmax(x)
   if size(x,1) == 0
        return missing
    else
        return(findmax(x))
    end
end 

"""
    collectscores(outpath, algs, scoref)

Collect scores on datasets in outpath, for specified algorithm and score function.
Raturns a DataFrame.
"""
function collectscores(outpath, algs, scoref)
    df = DataFrame()
    df[:dataset] = String[]
    for alg in algs
        df[Symbol(alg)] = Any[]
    end
    nalgs = size(algs,1)
    
    # collect dataset names
    fs = readdir(outpath)
    datasets = [x[1] for x in split.(fs, ".")]
    
    for (f,dataset) in zip(fs, datasets)
        _f = joinpath(outpath, f)
        df = [df; scoref(loadtable(_f, 5:9), algs)]
    end
    
    return df
end

"""
    maxauroc(data, algs)

Score algorithms according to their maximum auroc on a testing dataset 
averaged over experiment iterations.
"""
function maxauroc(data, algs)
    df = DataFrame()
    df[:dataset] = String[]
    for alg in algs
        df[Symbol(alg)] = Any[]
    end
    nalgs = size(algs,1)
    dataset = data[:dataset][1]

    row = Array{Any,1}(nalgs+1)
    row[2:end] = missing
    row[1] = dataset
    push!(df, reshape(row, 1, nalgs+1))
    for alg in algnames
        dfx = @from r in data begin
            @where r.algorithm == alg && r.dataset == dataset
            @select {r.iteration, r.test_auroc}
            @collect DataFrame
        end
            
        try
            # group this by iterations
            dfx = by(dfx, [:iteration], 
                d -> DataFrame(auroc = 
                    missmax(collect(skipmissing(d[:test_auroc])))))
            # and get the mean
            df[Symbol(alg)][1] = round(missmean(collect(skipmissing(dfx[:auroc]))),6)
        catch e
            if !isa(e, ArgumentError)
                nothing #warn(e)
            else
                throw(e)
            end
        end    
    end

    return df
end

"""
    trainauroc(data, algs)

Choose algorithm with parameters according to maximum auroc on training dataset,
then compute the score as average of testing auroc with these parameters over iterations.
"""
function trainauroc(data, algs)
    df = DataFrame()
    df[:dataset] = String[]
    for alg in algs
        df[Symbol(alg)] = Any[]
    end
    nalgs = size(algs,1)
    dataset = data[:dataset][1]

    row = Array{Any,1}(nalgs+1)
    row[2:end] = missing
    row[1] = dataset
    push!(df, reshape(row, 1, nalgs+1))
    for alg in algnames
        dfx = @from r in data begin
            @where r.algorithm == alg && r.dataset == dataset
            @select {r.settings, r.iteration, r.train_auroc, r.test_auroc}
            @collect DataFrame
        end
            
        try
            # mean aggregate it by settings
            traindf = by(dfx, [:settings],
                            d -> DataFrame(train_auroc = 
                            missmean(collect(skipmissing(d[:train_auroc])))))
            # get the best settings
            sort!(traindf, cols = :train_auroc, rev = true)
            topalg = ""
            for j in 1:size(traindf,1)
                if !ismissing(traindf[:train_auroc][j])
                    topalg = traindf[:settings][j]
                    break
                end
            end
            # and get the mean of the best setting test auroc over all iterations
            testdf = @from r in dfx begin
                     @where r.settings == topalg
                     @select {r.settings, r.iteration, r.test_auroc}
                     @collect DataFrame
            end
            df[Symbol(alg)][1] = round(missmean(collect(skipmissing(testdf[:test_auroc]))),6)
        catch e
            if !isa(e, ArgumentError)
                nothing
            else
                throw(e)
            end
        end    
    end
    
    return df

end

"""
    toprec(data, algs)

Choose algorithm with parameters according to precision on top 5% instances in training dataset,
then compute the score as average of testing auroc with these parameters over iterations.
"""
function topprec(data, algs)
    df = DataFrame()
    df[:dataset] = String[]
    for alg in algs
        df[Symbol(alg)] = Any[]
    end
    nalgs = size(algs,1)
    dataset = data[:dataset][1]

    row = Array{Any,1}(nalgs+1)
    row[2:end] = missing
    row[1] = dataset
    push!(df, reshape(row, 1, nalgs+1))
    for alg in algnames
        dfx = @from r in data begin
            @where r.algorithm == alg && r.dataset == dataset
            @select {r.settings, r.iteration, r.top_5p, r.test_auroc}
            @collect DataFrame
        end
            
        try
            # mean aggregate it by settings
            traindf = by(dfx, [:settings],
                            d -> DataFrame(top_5p = 
                            missmean(collect(skipmissing(d[:top_5p])))))
            # get the best settings
            sort!(traindf, cols = :top_5p, rev = true)
            topalg = ""
            for j in 1:size(traindf,1)
                if !ismissing(traindf[:top_5p][j])
                    topalg = traindf[:settings][j]
                    break
                end
            end
            # and get the mean of the best setting test auroc over all iterations
            testdf = @from r in dfx begin
                     @where r.settings == topalg
                     @select {r.settings, r.iteration, r.test_auroc}
                     @collect DataFrame
            end
            df[Symbol(alg)][1] = round(missmean(collect(skipmissing(testdf[:test_auroc]))),6)
        catch e
            if !isa(e, ArgumentError)
                nothing
            else
                throw(e)
            end
        end    
    end
    
    return df

end

"""
    meantime(data, algs, t)

Score algorithm on a dataset based on mean fit/predict times over iterations and parameter settings.
"""
function meantime(data, algs, t)
    @assert t in ["predict_time", "fit_time"]

    df = DataFrame()
    df[:dataset] = String[]
    for alg in algs
        df[Symbol(alg)] = Any[]
    end
    nalgs = size(algs,1)
    dataset = data[:dataset][1]

    row = Array{Any,1}(nalgs+1)
    row[2:end] = missing
    row[1] = dataset
    push!(df, reshape(row, 1, nalgs+1))
    for alg in algnames
        dfx = @from r in data begin
            @where r.algorithm == alg && r.dataset == dataset
            @select {r.settings, r.iteration, getfield(r, Symbol(t))}
            @collect DataFrame
        end
        rename!(dfx, :_3_, Symbol(t))

        try
            # mean aggregate it by settings
            a = round(missmean(collect(skipmissing(dfx[Symbol(t)]))),6)
            df[Symbol(alg)][1] = a
        catch e
            if !isa(e, ArgumentError)
                throw(e)
            else
                throw(e)
            end
        end    
    end
    
    return df
end