module napire

    using DataFrames
    using Printf

    import BayesNets
    import CSV
    import Distributed
    import Random
    import SharedArrays

    include("graphviz.jl")
    include("napireweb.jl")
    export napireweb
    export graphviz

    const ANSWERS_PER_SUBJECT = 5
    export ANSWERS_PER_SUBJECT

    function load(nodes::Dict{Symbol, UInt} = Dict{Symbol, UInt}(), connect::Array{Tuple{Symbol, Symbol, UInt}, 1} = Array{Tuple{Symbol, Symbol, UInt}, 1}();
            filename = joinpath(dirname(@__FILE__), "../data/napire.csv"), summary = true, all_items = false)
        #
        # CSV parsing
        #

        to_col_name = function(secname, number)
            return Symbol("$(String(secname))_$(@sprintf("%02d", number))")
        end

        data = CSV.read(filename; datarow = 1, delim = ';', quotechar = '"');
        data_meta = data[1:4, :]
        data = data[4:end, :]

        current_title = ""
        current_subtitle = ""
        current_framestart = 0
        items = Dict{Symbol, Set{Symbol}}()
        descriptions = Dict{Symbol, Union{Missing, String}}()
        for i in 1:size(data_meta)[2]
            if !ismissing(data_meta[1, i])
                current_title = data_meta[1, i]
                current_subtitle = ""
                current_framestart = i
            end
            if !ismissing(data_meta[2, i])
                current_subtitle = data_meta[2, i]
                current_framestart = i
            end

            secname = "$(current_title)_$(current_subtitle)"

            colname = to_col_name(secname, i - current_framestart)
            rename!(data, names(data)[i] => colname)
            descriptions[colname] = data_meta[3, i]

            if current_subtitle == "CODE" || current_subtitle == "CATEGORIES"
                if current_framestart == i
                    items[Symbol(secname)] = Set{Symbol}()
                end

                data[colname] = .! ismissing.(data[colname])
                push!(items[Symbol(secname)], colname)
            elseif current_subtitle == "FAILURE"
                data[colname] = data[colname] .== "1"
            end
        end

        #
        # Make sure the data is properly sorted so
        # subjects are identifiable before cross-validation
        #
        sort!(data, (:IDENTIFIERS_SUBJECT_00, :IDENTIFIERS_RANK_00) )
        subjects = unique(data[:IDENTIFIERS_SUBJECT_00])
        sort!(subjects)

        #
        # node-wise filtering
        #
        for (node_type, min_weight) in nodes
            for node in items[node_type]
                if sum(data[node]) < min_weight
                    deletecols!(data, node)
                    delete!(items[node_type], node)
                    delete!(descriptions, node)
                end
            end
        end

        #
        # edge-wise filtering
        #
        all_nodes::Set{Symbol} = Set{Symbol}()
        all_edges::Dict{Pair{Symbol, Symbol}, Int64} = Dict{Pair{Symbol, Symbol}, Int64}()

        for connect_pair in connect
            nodes, edges= __create_edges(data, items, connect_pair[1], connect_pair[2], connect_pair[3])
            all_nodes = union(all_nodes, nodes)
            all_edges = merge(all_edges, edges)
        end

        # remove now unused data from previously created structures
        data = data[:, collect(all_nodes)]

        if !all_items
            for key in keys(items)
                items[key] = intersect(items[key], all_nodes)
            end

            for key in keys(descriptions)
                if !in(key, all_nodes)
                    delete!(descriptions, key)
                end
            end
        end

        #
        # summary
        #

        if summary
            println("Nodes: ", length(all_nodes))
            println("Descriptions: ", length(descriptions))
            println("Edges: ", length(all_edges))
            println("Samples: ", size(data)[1])
        end

        return (data = data, items = items, descriptions = descriptions,
            edges = all_edges, nodes = all_nodes, subjects = subjects)
    end
    export load

    function __create_edges(data, items, from ::Symbol, to ::Symbol, minimum_edge_weight)
        edges = Dict{Pair{Symbol, Symbol}, Int64}()

        for from_node in items[from]
            for to_node in items[to]
                edges[(from_node => to_node)] = 0

                for i in 1:size(data)[1]
                    if data[i, from_node] && data[i, to_node]
                        edges[(from_node => to_node)] += 1
                    end
                end
            end
        end

        edges = filter((kv) -> kv.second >= minimum_edge_weight, edges)
        nodes = Set{Symbol}()
        for (n1, n2) in keys(edges)
            push!(nodes, n1)
            push!(nodes, n2)
        end

        return nodes, edges
    end


    function plot(data, output_type = graphviz.default_output_type; shape = shape(n) = "ellipse", penwidth_factor = 5, ranksep = 3, label = identity)
        graph_layout = data.edges
        graph = graphviz.Dot(data.nodes, keys(graph_layout))

        for node in data.nodes
            graphviz.set(graph, node, graphviz.label, label(node))
            graphviz.set(graph, node, graphviz.margin, 0.025)
            graphviz.set(graph, node, graphviz.shape, shape(node))
        end

        graphviz.set(graph, graphviz.ranksep, ranksep)

        max_edges = isempty(graph_layout) ? 0 : maximum(values(graph_layout))

        for ((n1, n2), n_edges) in graph_layout
            edge_weight = n_edges / max_edges
            alpha = @sprintf("%02x", round(edge_weight * 255))

            graphviz.set(graph, (n1 => n2), graphviz.penwidth, edge_weight * penwidth_factor)
            graphviz.set(graph, (n1 => n2), graphviz.color, "#000000$(alpha)")
        end

        graphviz.plot(graph, output_type)
    end
    export plot

    function bayesian_train(data, subsample = nothing)
        # extract graph layout
        graph_layout = Tuple(keys(data.edges))

        graph_data = data.data
        if subsample != nothing
            graph_data = graph_data[subsample,:]
        end

        if size(graph_data, 2) > 0
            # remove completely empty lines, BayesNets does not like them
            graph_data = graph_data[sum(convert(Matrix, graph_data), dims = 2)[:] .> 0, :]
        end

        # add one, BayesNets expects state labelling to be 1-based
        graph_data = DataFrame(colwise(x -> convert(Array{Int64}, x) .+ 1, data.data), names(data.data))

        return BayesNets.fit(BayesNets.DiscreteBayesNet, graph_data, graph_layout)
    end
    export bayesian_train

    function add_inference_methods(m = BayesNets)
        ns = names(m)
        for n in ns
            if !isdefined(m, n)
                continue
            end

            f = getfield(m, n)
            if isa(f, Type) && f != BayesNets.InferenceMethod && f <: BayesNets.InferenceMethod
                inference_methods[string(f)] = f
            end
        end
    end

    inference_methods = Dict{String, Type}()
    add_inference_methods(BayesNets)
    default_inference_method = inference_methods["BayesNets.GibbsSamplingNodewise"]

    function predict(bn::BayesNets.DiscreteBayesNet, query::Set{Symbol}, evidence::Dict{Symbol, Bool}, inference_method::String)
        return predict(bn, query, evidence, inference_methods[inference_method])
    end

    function predict(bn::BayesNets.DiscreteBayesNet, query::Set{Symbol}, evidence::Dict{Symbol, Bool}, inference_method::Type = default_inference_method)

        evidence = Dict{Symbol, Any}( kv.first => convert(Int8, kv.second) + 1 for kv in evidence)

        f = BayesNets.infer(inference_method(), bn, collect(query), evidence = evidence)
        results = Dict{Symbol, Float64}()
        for symbol in query
            results[symbol] = sum(f[BayesNets.Assignment(symbol => 2)].potential)
        end

        return results
    end
    export predict

    function plot_prediction(data, query, evidence, results, output_type = graphviz.default_output_type; half_cell_width = 40, shorten = false, kwargs...)
        function label(node)
            plot_label(n) = shorten ? string(n)[1:1] * string(n)[end - 2:end] : n

            if !in(node, query) && !haskey(evidence, node) && !haskey(results, node)
                return plot_label(node)
            end

            label = """< <TABLE BORDER="0" CELLBORDER="1" CELLSPACING="0">"""
            label *= """<TR><TD COLSPAN="2">$(plot_label(node))</TD></TR>"""
            if haskey(results, node)
                false_val = @sprintf("%d", round( (1 - results[node]) * 100))
                true_val = @sprintf("%d", round(results[node] * 100))
                label *= """<TR><TD WIDTH="$half_cell_width">$(false_val)%</TD><TD WIDTH="$half_cell_width">$(true_val)%</TD></TR>"""
            end

            if haskey(evidence, node)
                false_color = evidence[node] ? "white" : "grey"
                true_color = evidence[node] ? "grey" : "white"
                label *= """<TR><TD WIDTH="$half_cell_width" BGCOLOR="$false_color">  </TD><TD WIDTH="$half_cell_width" BGCOLOR="$true_color">  </TD></TR>"""
            end
            label *= "</TABLE>>"
        end

        function shape(node)
            if !in(node, query) && !haskey(evidence, node) && !haskey(results, node)
                return "ellipse"
            else
                return "plaintext"
            end
        end

        plot(data, output_type; shape = shape, label = label, kwargs...)
    end
    export plot_prediction

    function plot_legend(output_type = graphviz.default_output_type, kwargs...)
        plot_prediction( ( nodes = [ :unknown, :output, :present, :absent, :result ], edges = Dict{Pair{Symbol, Symbol}, Int}()),
                        Set{Symbol}([:output]), Dict{Symbol, Bool}(:present => true, :absent => false),
                        Dict{Symbol, Float64}( :result => 0.3 ), output_type; shorten = false)
    end
    export plot_legend

    function validate(data, output_variables::Set{Symbol}, subsample_size::Int, iterations::Int, inference_method::String)
        return validate(data, output_variables, subsample_size, iterations, inference_methods[inference_method])
    end

    function validate(data, output_variables::Set{Symbol}, subsample_size::Int, iterations::Int, inference_method::Type = default_inference_method)

        evidence_variables = setdiff(Set{Symbol}(names(data.data)), output_variables)
        per_subj = collect(0:(ANSWERS_PER_SUBJECT - 1))

        progress_array = SharedArrays.SharedArray{Int}( (iterations, subsample_size * ANSWERS_PER_SUBJECT))
        task = @async begin
            iteration_tasks = []
            for i in 1:iterations
                it_task = @async begin
                    println("Validation run " * string(i))
                    samples = Random.randperm(length(data.subjects)) .- 1

                    validation_samples = samples[1:subsample_size]   .* ANSWERS_PER_SUBJECT
                    training_samples   = samples[subsample_size + 1:end] .* ANSWERS_PER_SUBJECT

                    validation_samples = reduce(vcat, [ s .+ per_subj for s in validation_samples ]) .+ 1
                    training_samples   = reduce(vcat, [ s .+ per_subj for s in training_samples ]) .+ 1

                    @assert length(validation_samples) == subsample_size * ANSWERS_PER_SUBJECT
                    @assert length(validation_samples) + length(training_samples) == nrow(data.data)
                    @assert length(intersect(validation_samples, training_samples)) == 0

                    @assert min(validation_samples...) > 0
                    @assert min(training_samples...)   > 0
                    @assert max(validation_samples...) <= nrow(data.data)
                    @assert max(training_samples...)   <= nrow(data.data)

                    bn = bayesian_train(data, training_samples)

                    subtasks = Distributed.@distributed __merge_arrays for si in 1:length(validation_samples)
                        s = validation_samples[si]

                        println(string(si) * " of " * string(subsample_size * ANSWERS_PER_SUBJECT))
                        evidence = Dict{Symbol, Bool}()
                        for ev in evidence_variables
                            evidence[ev] = data.data[s, ev]
                        end

                        expected = Dict{Symbol, Bool}()
                        for ov in output_variables
                            expected[ov] = data.data[s, ov]
                        end

                        prediction = predict(bn, output_variables, evidence, inference_method)
                        progress_array[i, si] += 1
                        [ (expected, prediction) ]
                    end

                    fetch(subtasks)
                end

                push!(iteration_tasks, it_task)
            end
            [ fetch(it_task) for it_task in iteration_tasks ]
        end

        return progress_array, task
    end

    function __merge_arrays(a1, a2)
        append!(a1, a2); a1
    end

    function calc_metrics(data = nothing)
        return Dict((s => getfield(napire.Metrics, s)(data))
                        for s in names(napire.Metrics; all = true)
                        if isa(getfield(napire.Metrics, s), Function) && s != :eval && s != :include)
    end

    module Metrics
        function binary_accuracy(data)
            total = 0
            correct = 0
            for iteration_data in data
                for (expected, predicted) in iteration_data
                    total += length(expected)
                    correct += length([ s for s in keys(expected) if expected[s] == (predicted[s] > 0.5) ])
                end
            end
            return correct / total
        end

        function brier_score(data)
            bs = 0
            ns = 0
            for iteration_data in data
                for (expected, predicted) in iteration_data
                    bs += sum([ (convert(Int, expected[s]) - predicted[s])^2 for s in keys(expected) ])
                    ns += length(expected)
                end
            end
            return bs / ns
        end
    end
end
