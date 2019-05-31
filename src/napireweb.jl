module web
    import Base64
    import Distributed
    import HTTP
    import JSON
    import Serialization
    import SharedArrays
    import Sockets

    import napire

    struct TimeoutException <: Exception end

    function query_legend()
        return napire.plot_legend(napire.graphviz.png)
    end

    function options(dict, default)
        return () -> begin d = string(default)
            opts = [ d ]
            append!(opts, sort([ k for k in keys(dict) if k != d ]))

            return opts
        end
    end

    STARTED_TASKS = nothing
    RESULT_DIRECTORY = nothing
    function load_started_tasks(result_directory::String)
        global RESULT_DIRECTORY, STARTED_TASKS
        RESULT_DIRECTORY = result_directory
        files = sort([ f for f in readdir(result_directory) if occursin(r"^[0-9]+\.ser$", f) ])
        files = [ Serialization.deserialize(joinpath(result_directory, f)) for f in files ]

        STARTED_TASKS = Dict{Int64, Any}(f[2] => f for f in files)
    end

    struct SerTask
        state::Symbol
        result::Any
    end

    function task_state(t::Task)
        if !istaskdone(t)
            return :RUNNING
        elseif t.state == :failed
            return :FAILED
        else
            return :DONE
        end
    end

    function task_state(t::SerTask)
        return t.state
    end

    function task_fetch(t::Task, block = false)
        if !block && !istaskdone(t)
            return nothing
        end

        try
            return Base.fetch(t)
        catch e
            return sprint(showerror, e, t.backtrace)
        end
    end

    function task_fetch(t::SerTask, block = false)
        return t.result
    end

    function task_serialize(t::NamedTuple, printresult = true, action = (t) -> nothing)

        state = task_state(t.task)
        result = printresult ? task_fetch(t.task) : nothing

        if result != nothing && state == :DONE
            if t.type == :TASK_VALIDATION
                result = napire.calc_metrics(result)
            elseif t.type == :TASK_INFERENCE
                result = "data:image/png;base64," * Base64.base64encode(result)
            end
        end

        action(t)

        task_data = Dict( k => v for (k, v) in zip(keys(t), t) if k != :task)
        task_data[:steps_done]  = task_state(t.steps_done) == :DONE  ? sum(task_fetch(t.steps_done)) : 0
        task_data[:interruptor] = task_state(t.interruptor) == :DONE ? sum(task_fetch(t.interruptor)) : 0
        task_data[:state] = state
        task_data[:result] = result

        return task_data
    end

    function task_serialize(tid::Union{Nothing, Int64}, args...)
        if tid == nothing
            return [ task_serialize(STARTED_TASKS[tid], args...) for tid in sort(collect(keys(STARTED_TASKS))) ]
        else
            return task_serialize(STARTED_TASKS[tid], args...)
        end
    end

    function tasks(; id = nothing, printresult = "false")
        return task_serialize(id == nothing ? id : parse(Int64, id), parse(Bool, printresult))
    end

    function tasks_cancel(; id = nothing, printresult = "false")
        function cancel(t)
            if task_state(t.task) != :RUNNING
                return
            end

            interruptor = fetch(t.interruptor)
            interruptor .+= 1
        end

        return task_serialize(id == nothing ? id : parse(Int64, id), parse(Bool, printresult), cancel)
    end

    function tasks_delete(; id = nothing, printresult = "false")
        function delete(t)
            if task_state(t.task) == :RUNNING
                return
            end

            delete!(STARTED_TASKS, t.id)
            storage_file = joinpath(RESULT_DIRECTORY,  string(t.id) * ".ser")
            rm(storage_file)
        end

        return task_serialize(id == nothing ? id : parse(Int64, id), parse(Bool, printresult), delete)
    end

    available_workers = [ ]
    uncreated_workers = length(Sys.cpu_info())

    function __run_task(task_type, task_workers, fun,  progress_array_shape, query_dict)
        global available_workers, uncreated_workers

        if uncreated_workers + length(available_workers) < task_workers
            throw(WebApplicationException(507, "Too many workers demanded"))
        end

        new_workers = max(0, task_workers - length(available_workers))
        existing_workers = task_workers - new_workers

        reused_workers = []
        if existing_workers > 0
            reused_workers = available_workers[1:(task_workers - new_workers)]
            available_workers = available_workers[(task_workers - new_workers + 1):end]

        end
        uncreated_workers -= new_workers

        println(string(length(available_workers)) * " unused workers remaining")
        println(string(uncreated_workers) * " workers can still be created")
        println("Creating " * string(new_workers) * " new workers")
        println("Re-using " * string(existing_workers) * " old workers")

        setup_task = @async begin
            return (
                pool = Distributed.WorkerPool( [
                    reused_workers...,
                    Distributed.addprocs(new_workers, exename = joinpath(dirname(@__DIR__), "run_worker.sh"))...
                    ]),
                progress_array = SharedArrays.SharedArray{Int}( progress_array_shape ),
                interruptor    = SharedArrays.SharedArray{Int}( (1, ) )
            )
        end

        progress_array_task = @async fetch(setup_task).progress_array
        interruptor_task = @async fetch(setup_task).interruptor

        task = @async begin
            setup = fetch(setup_task)

            timeout = get(query_dict, "timeout", -1)
            start = time()
            try
                remotetask = Distributed.remotecall(fun, setup.pool, query_dict; pool = setup.pool, progress_array = setup.progress_array)
                while !isready(remotetask) && sum(setup.interruptor) == 0 && (timeout <= 0 || timeout > (time() - start) / 60 / 60)
                    sleep(1)
                end

                if sum(setup.interruptor) > 0
                    throw(InterruptException())
                end
                println("timeout: " * string(timeout))
                println("elapsed: " * string((time() - start) / 60 / 60))

                if timeout <= (time() - start) / 60 / 60
                    throw(TimeoutException())
                end

                return fetch(remotetask)
            catch e
                kills = [ worker.config.process  for worker in Distributed.PGRP.workers if in(worker.id, setup.pool.workers) ]
                for process in kills;
                    println("Killing " * string(getpid(process)))
                    kill(process);
                end
                rethrow(e)
            end
        end

        task_id = isempty(STARTED_TASKS) ? 1 : maximum(keys(STARTED_TASKS)) + 1
        steps_total = prod(progress_array_shape)

        STARTED_TASKS[task_id] = (
            type = task_type, id = task_id, query = query_dict,
            steps_done = progress_array_task, steps_total = steps_total,
            interruptor = interruptor_task, task = task)

        storage_file = joinpath(RESULT_DIRECTORY,  string(task_id) * ".ser")

        @async begin
            result = task_fetch(task, true)
            pool, progress_array, interruptor = fetch(setup_task)

            if task_state(task) == :DONE
                append!(available_workers, collect(pool.workers))
            else
                uncreated_workers += length(pool.workers)
            end

            interruptor = SerTask(:DONE, collect(interruptor))
            steps_done = SerTask(:DONE, [ sum(progress_array) ])

            task_data = (
                type = task_type, id = task_id, query = query_dict,
                steps_done = steps_done, steps_total = steps_total,
                interruptor = interruptor, task = SerTask(task_state(task), result))

            STARTED_TASKS[task_id] = task_data
            Serialization.serialize(storage_file, task_data)
        end

        return task_id
    end

    function plot(query_dict = nothing)
        data = __load_graph(query_dict, "false")

        query = Set(Symbol(q) for q in get(query_dict, "query", []))
        evidence = Dict{Symbol, Bool}( Symbol(kv.first) => convert(Bool, kv.second) for kv in get(query_dict, "evidence", Dict()))
        return "data:image/png;base64," * Base64.base64encode(napire.plot_prediction(data, query, evidence, Dict(), napire.graphviz.png))
    end

    function infer(query_dict = nothing)
        query_dict["inference_method"] = string(get(query_dict, "inference_method", napire.default_inference_method))
        query_dict["query"] = Set(Symbol(q) for q in get(query_dict, "query", []))
        query_dict["evidence"] = Dict{Symbol, Bool}( Symbol(kv.first) => convert(Bool, kv.second) for kv in get(query_dict, "evidence", Dict()))
        query_dict["model"] = Symbol(get(query_dict, "model", napire.default_model))

        if length(query_dict["query"]) == 0
            throw(WebApplicationException(400, "No query defined"))
        end

        return __run_task(:TASK_INFERENCE, 1, __infer, (1, ), query_dict)
    end

    function __infer(query_dict; kwargs...)
        data = __load_graph(query_dict, "false")

        md = napire.train(data, Val(query_dict["model"]))
        results = napire.predict(md, query_dict["inference_method"], query_dict["query"], query_dict["evidence"])
        return napire.plot_prediction(data, query_dict["query"], query_dict["evidence"], results, napire.graphviz.png)
    end

    function __load_graph(query_dict, all_items)
        dataset = string(get(query_dict, "dataset", napire.default_dataset))

        nodes_raw = get(query_dict, "nodes", [])
        nodes::Array{Tuple{Symbol,Bool,UInt64}} = [ ( Symbol(n[1]), convert(Bool, n[2]), convert(UInt, n[3]) ) for n in nodes_raw ]

        connect_raw = get(query_dict, "connect", [])
        connect::Array{Tuple{Symbol,Symbol,Bool,UInt64}} = [ ( Symbol(c[1]),  Symbol(c[2]), convert(Bool, c[3]), convert(UInt, c[4]) ) for c in connect_raw ]

        return napire.load(dataset, nodes, connect, parse(Bool, all_items))
    end

    function items(query_dict; all_items = "false")
        data = __load_graph(query_dict, all_items)
        return Dict(
                :items => data.items,
                :edges => data.edges)
    end

    function descriptions(query_dict; all_items = "false")
        return __load_graph(query_dict, all_items).descriptions
    end

    function validate(query_dict)
        query_dict["inference_method"] = string(get(query_dict, "inference_method", napire.default_inference_method))
        query_dict["query"] = Set{Symbol}(Symbol(ov) for ov in get(query_dict, "query", []))
        query_dict["model"] = Symbol(get(query_dict, "model", napire.default_model))
        query_dict["baseline_model"] = Symbol(get(query_dict, "baseline_model", napire.default_baseline_model))

        if length(query_dict["query"]) == 0
            throw(WebApplicationException(400, "No query defined"))
        end

        return __run_task(:TASK_VALIDATION, pop!(query_dict, "workers", 4), __validate, (query_dict["iterations"], query_dict["subsample_size"]), query_dict)
    end

    function __validate(query_dict; kwargs...)
        data = __load_graph(query_dict, "false")

        return napire.validate(data, query_dict["iterations"], query_dict["subsample_size"], query_dict["inference_method"],
                                query_dict["query"], query_dict["zero_is_unknown"], query_dict["model"],
                                query_dict["baseline_model"]; kwargs...)
    end

    const APISPEC = Dict{NamedTuple, NamedTuple}(
        (path = "/inference", method = "GET") => (fn = options(napire.inference_methods, napire.default_inference_method), content = "application/json"),
        (path = "/datasets", method = "GET") => (fn = options(napire.datasets, napire.default_dataset), content = "application/json"),
        (path = "/models", method = "GET")  => (fn = options(napire.models, napire.default_model), content = "application/json"),
        (path = "/descriptions", method = "POST") => (fn = descriptions, content = "application/json"),
        (path = "/items", method = "POST")  => (fn = items, content = "application/json"),
        (path = "/plot", method = "POST") => (fn = plot, content = "image/png"),
        (path = "/infer", method = "POST") => (fn = infer, content = "application/json"),
        (path = "/query_legend", method = "GET") => (fn = query_legend, content = "image/png"),
        (path = "/validate", method = "POST")  => (fn = validate, content = "application/json"),
        (path = "/tasks", method = "GET")  => (fn = tasks, content = "application/json"),
        (path = "/tasks", method = "POST")  => (fn = tasks_cancel, content = "application/json"),
        (path = "/tasks", method = "DELETE")  => (fn = tasks_delete, content = "application/json")
    )

    const BODYMETHODS = Set([ "POST", "PUT" ])

    const REQUEST_CONVERSION = Dict(
        "application/json" => (b) -> JSON.parse(String(b)),
        "" => (b) -> nothing
    )

    const RESPONSE_CONVERSION = Dict(
        "application/json" => (b) -> JSON.json(b)
    )

    const EXTENSION_MAP = Dict(
        r"^.*\.json$"  => "application/json",
        r"^.*\.js$"  => "text/javascript",
        r"^.*\.css$" => "text/css",
        r"^.*\.html$" => "text/html",
        r"^.*\.ico$" => "image/x-icon"
    )

    struct WebApplicationException <: Exception
        code::Int64
        msg::String
    end

    function WebApplicationException(code::Int64)
        return WebApplicationException(code, "")
    end

    function dispatch(request::HTTP.Message)
        uri = parse(HTTP.URI, request.target)
        key = (path = uri.path, method = request.method)
        if !haskey(APISPEC, key)
            throw(WebApplicationException(404))
        end
        endpoint = APISPEC[key]

        params = Dict(Symbol(k) => v for (k, v) in HTTP.queryparams(uri))

        body_content_type = HTTP.header(request, "Content-Type", "")
        if !haskey(REQUEST_CONVERSION, body_content_type)
            throw(WebApplicationException(400, "Unknown Content-Type"))
        end

        body = nothing
        try
            body = REQUEST_CONVERSION[body_content_type](request.body)
        catch e
            throw(WebApplicationException(400, "Unparsable body: " * e.msg))
        end

        try
            if body != nothing
                response = endpoint.fn(body; params...)
            else
                response = endpoint.fn(; params...)
            end
        catch e
            if isa(e, ErrorException)
                throw(WebApplicationException(400, "Bad query parameters: " * e.msg))
            end
            rethrow(e)
        end

        if isa(response, HTTP.Response)
            return response
        end

        if haskey(RESPONSE_CONVERSION, endpoint.content)
            response = RESPONSE_CONVERSION[endpoint.content](response)
        end

        return HTTP.Response(response == nothing ? 204 : 200, [ ("Content-Type", endpoint.content) ]; body = response, request = request)
    end

    function respond(request::HTTP.Message)
        try
            return dispatch(request)
        catch e
            if isa(e, WebApplicationException)
                return HTTP.Response(e.code, [ ("Content-Type", "text/plain") ]; body = e.msg, request = request)
            else
                for (exc, bt) in Base.catch_stack()
                   showerror(stdout, exc, bt)
                   println()
                end
                return HTTP.Response(500, [ ("Content-Type", "text/plain") ]; body = string(e), request= request)
            end
        end
    end

    function serve_file(path, file)
        if path[1] != '/'
            path = "/" * path
        end

        final_mime = "application/octet_stream"
        for (regex, mime) in EXTENSION_MAP
            if match(regex, path) != nothing
                final_mime = mime
            end
        end

        ep = (fn = (; kwargs...) -> read(file), content = final_mime)
        APISPEC[(path = "/web" * path, method = "GET")] = ep

        newpath = replace(path, r"/index.html$" => "/")
        if newpath != path
            APISPEC[(path = "/web" * newpath, method = "GET")] = ep # with /
            APISPEC[(path = "/web" * newpath[2:end], method = "GET")] = ep # without /
        end
    end

    function redirect(path, destination)
        APISPEC[(path = path, method = "GET")] = (
            fn = (; ) -> HTTP.Response(301, [ ("Location", destination) ]), content = nothing)
    end

    function start(webdir::String, resultdir::String)
        mkpath(resultdir)
        load_started_tasks(resultdir)

        for (rootpath, dirs, files) in walkdir(webdir; follow_symlinks = false)
            for file in files
                fullpath = joinpath(rootpath, file)
                serve_file(relpath(fullpath, webdir), fullpath)
            end
        end
        redirect("/", "/web")

        start()
    end

    function start()
        println("Starting napire analysis REST service")
        HTTP.serve(respond, Sockets.localhost, 8888)
    end
    export start
end
