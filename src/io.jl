export create_internal_structures,
    save_solution_to_file, compute_assets_partitions!, compute_flows_partitions!

"""
    graph, representative_periods, timeframe  = create_internal_structures(connection)

Return the `graph`, `representative_periods`, and `timeframe` structures given the input dataframes structure.

The details of these structures are:

  - `graph`: a MetaGraph with the following information:

      + `labels(graph)`: All assets.
      + `edge_labels(graph)`: All flows, in pair format `(u, v)`, where `u` and `v` are assets.
      + `graph[a]`: A [`TulipaEnergyModel.GraphAssetData`](@ref) structure for asset `a`.
      + `graph[u, v]`: A [`TulipaEnergyModel.GraphFlowData`](@ref) structure for flow `(u, v)`.

  - `representative_periods`: An array of
    [`TulipaEnergyModel.RepresentativePeriod`](@ref) ordered by their IDs.

  - `timeframe`: Information of
    [`TulipaEnergyModel.Timeframe`](@ref).
"""
function create_internal_structures(connection)

    # Create tables that are allowed to be missing
    tables_allowed_to_be_missing = [
        "assets_rep_periods_partitions"
        "assets_timeframe_partitions"
        "assets_timeframe_profiles"
        "flows_rep_periods_partitions"
        "groups_data"
        "profiles_timeframe"
    ]
    for table in tables_allowed_to_be_missing
        _check_if_table_exist(connection, table)
    end

    # Get the years struct ordered by year
    years = [
        Year(row.year, row.length, row.is_milestone) for row in DBInterface.execute(
            connection,
            "SELECT *
             FROM year_data
             ORDER BY year",
        )
    ]

    milestone_years = [year.id for year in years]

    # Calculate the weights from the "rep_periods_mapping" table in the connection
    weights = Dict(
        year => [
            row.weight for row in DBInterface.execute(
                connection,
                "SELECT rep_period, SUM(weight) AS weight
                    FROM rep_periods_mapping
                    WHERE year = $year
                    GROUP BY rep_period
                    ORDER BY rep_period",
            )
        ] for year in milestone_years
    )

    representative_periods = Dict{Int,Vector{RepresentativePeriod}}(
        year => [
            RepresentativePeriod(weights[year][row.rep_period], row.num_timesteps, row.resolution) for row in TulipaIO.get_table(Val(:raw), connection, "rep_periods_data") if
            row.year == year
        ] for year in milestone_years
    )

    # Calculate the total number of periods and then pipe into a Dataframe to get the first value of the df with the num_periods
    num_periods, = DuckDB.query(connection, "SELECT MAX(period) AS period FROM rep_periods_mapping")

    timeframe = Timeframe(num_periods.period, TulipaIO.get_table(connection, "rep_periods_mapping"))

    groups = [Group(row...) for row in TulipaIO.get_table(Val(:raw), connection, "groups_data")]

    _query_data_per_year(table_name, col, year_col; where_pairs...) = begin
        # Make sure valid year columns are used
        @assert year_col in ("milestone_year", "commission_year")
        year_prefix = replace(year_col, "_year" => "")
        # Make sure we are at the right table
        @assert table_name in ("asset_$year_prefix", "flow_$year_prefix")
        _q = "SELECT $year_col, $col FROM $table_name"
        if length(where_pairs) > 0
            _q *=
                " WHERE " *
                join(("$k=$(TulipaIO.FmtSQL.fmt_quote(v))" for (k, v) in where_pairs), " AND ")
        end
        DuckDB.query(connection, _q)
    end

    function _get_data_per_year(table_name, col; where_pairs...)
        year_prefix = replace(table_name, "asset_" => "", "flow_" => "")
        @assert year_prefix in ("milestone", "commission")
        year_col = year_prefix * "_year"
        @assert table_name in ("asset_$year_prefix", "flow_$year_prefix")

        result = _query_data_per_year(table_name, col, year_col; where_pairs...)
        Dict(row[Symbol(year_col)] => getproperty(row, Symbol(col)) for row in result)
    end

    _query_data_per_both_years(table_name, col; where_pairs...) = begin
        _q = "SELECT $col, milestone_year, commission_year FROM $table_name"
        if length(where_pairs) > 0
            _q *=
                " WHERE " *
                join(("$k=$(TulipaIO.FmtSQL.fmt_quote(v))" for (k, v) in where_pairs), " AND ")
        end
        DuckDB.query(connection, _q)
    end

    function _get_data_per_both_years(table_name, col; where_pairs...)
        result = _query_data_per_both_years(table_name, col; where_pairs...)
        T = result.types[1] # First column is the one with out query
        result_dict = Dict{Int,Dict{Int,T}}()
        for row in result
            if !haskey(result_dict, row.milestone_year)
                result_dict[row.milestone_year] = Dict{Int,T}()
            end
            result_dict[row.milestone_year][row.commission_year] = getproperty(row, Symbol(col))
        end
        return result_dict
    end

    asset_data = [
        row.asset => begin
            _where = (asset = row.asset,)
            GraphAssetData(
                # From asset table
                row.type,
                row.group,
                row.capacity,
                row.min_operating_point,
                row.investment_method,
                row.investment_integer,
                row.technical_lifetime,
                row.economic_lifetime,
                row.discount_rate,
                if ismissing(row.consumer_balance_sense)
                    MathOptInterface.EqualTo(0.0)
                else
                    MathOptInterface.GreaterThan(0.0)
                end,
                row.capacity_storage_energy,
                row.is_seasonal,
                row.use_binary_storage_method,
                row.unit_commitment,
                row.unit_commitment_method,
                row.unit_commitment_integer,
                row.ramping,
                row.storage_method_energy,
                row.energy_to_power_ratio,
                row.investment_integer_storage_energy,
                row.max_ramp_up,
                row.max_ramp_down,

                # From asset_milestone table
                _get_data_per_year("asset_milestone", "investable"; _where...),
                _get_data_per_year("asset_milestone", "peak_demand"; _where...),
                _get_data_per_year("asset_milestone", "storage_inflows"; _where...),
                _get_data_per_year("asset_milestone", "initial_storage_level"; _where...),
                _get_data_per_year("asset_milestone", "min_energy_timeframe_partition"; _where...),
                _get_data_per_year("asset_milestone", "max_energy_timeframe_partition"; _where...),
                _get_data_per_year("asset_milestone", "units_on_cost"; _where...),

                # From asset_commission table
                _get_data_per_year("asset_commission", "fixed_cost"; _where...),
                _get_data_per_year("asset_commission", "investment_cost"; _where...),
                _get_data_per_year("asset_commission", "investment_limit"; _where...),
                _get_data_per_year("asset_commission", "fixed_cost_storage_energy"; _where...),
                _get_data_per_year("asset_commission", "investment_cost_storage_energy"; _where...),
                _get_data_per_year(
                    "asset_commission",
                    "investment_limit_storage_energy";
                    _where...,
                ),

                # From asset_both
                _get_data_per_both_years("asset_both", "active"; _where...),
                _get_data_per_both_years("asset_both", "decommissionable"; _where...),
                _get_data_per_both_years("asset_both", "initial_units"; _where...),
                _get_data_per_both_years("asset_both", "initial_storage_units"; _where...),
            )
        end for row in TulipaIO.get_table(Val(:raw), connection, "asset")
    ]

    flow_data = [
        (row.from_asset, row.to_asset) => begin
            _where = (from_asset = row.from_asset, to_asset = row.to_asset)
            GraphFlowData(
                # flow
                row.carrier,
                row.is_transport,
                row.capacity,
                row.technical_lifetime,
                row.economic_lifetime,
                row.discount_rate,
                row.investment_integer,

                # flow_milestone
                _get_data_per_year("flow_milestone", "investable"; _where...),
                _get_data_per_year("flow_milestone", "variable_cost"; _where...),

                # flow_commission
                _get_data_per_year("flow_commission", "fixed_cost"; _where...),
                _get_data_per_year("flow_commission", "investment_cost"; _where...),
                _get_data_per_year("flow_commission", "efficiency"; _where...),
                _get_data_per_year("flow_commission", "investment_limit"; _where...),

                # flow_both
                _get_data_per_both_years("flow_both", "active"; _where...),
                _get_data_per_both_years("flow_both", "decommissionable"; _where...),
                _get_data_per_both_years("flow_both", "initial_export_units"; _where...),
                _get_data_per_both_years("flow_both", "initial_import_units"; _where...),
            )
        end for row in TulipaIO.get_table(Val(:raw), connection, "flow")
    ]

    num_assets = length(asset_data) # we only look at unique asset names

    name_to_id = Dict(value.first => idx for (idx, value) in enumerate(asset_data))

    _graph = Graphs.DiGraph(num_assets)
    for flow in flow_data
        from_id, to_id = flow[1]
        Graphs.add_edge!(_graph, name_to_id[from_id], name_to_id[to_id])
    end

    graph = MetaGraphsNext.MetaGraph(_graph, asset_data, flow_data, nothing, nothing, nothing)

    # TODO: Move these function calls to the correct place
    tmp_create_partition_tables(connection)
    tmp_create_union_tables(connection)
    tmp_create_lowest_resolution_table(connection)

    df = TulipaIO.get_table(connection, "asset_time_resolution")
    gdf = DataFrames.groupby(df, [:asset, :year, :rep_period])
    for ((a, year, rp), _df) in pairs(gdf)
        if !haskey(graph[a].rep_periods_partitions, year)
            graph[a].rep_periods_partitions[year] = Dict{Int,Vector{TimestepsBlock}}()
        end
        graph[a].rep_periods_partitions[year][rp] =
            map(r -> r[1]:r[2], zip(_df.time_block_start, _df.time_block_end))
    end
    df = TulipaIO.get_table(connection, "flow_time_resolution")
    gdf = DataFrames.groupby(df, [:from_asset, :to_asset, :year, :rep_period])
    for ((u, v, year, rp), _df) in pairs(gdf)
        if !haskey(graph[u, v].rep_periods_partitions, year)
            graph[u, v].rep_periods_partitions[year] = Dict{Int,Vector{TimestepsBlock}}()
        end
        graph[u, v].rep_periods_partitions[year][rp] =
            map(r -> r[1]:r[2], zip(_df.time_block_start, _df.time_block_end))
        P = graph[u, v].rep_periods_partitions[year][rp]
    end

    #=
    For timeframe, This SQL query retrieves the names of assets from the `assets_data` table
    along with their corresponding partition specifications from the `assets_timeframe_partitions` table,
    if they exist. If a specification or partition is not available, it defaults to 'uniform' and '1' respectively.
    The query only includes assets marked as seasonal (`is_seasonal` column) in the `assets_data` table.
    =#
    find_assets_partitions_query = """
         SELECT asset_both.asset,
                 IFNULL(assets_timeframe_partitions.specification, 'uniform') AS specification,
                 IFNULL(assets_timeframe_partitions.partition, '1') AS partition
         FROM asset_both
         LEFT JOIN asset
            ON asset.asset = asset_both.asset
         LEFT JOIN assets_timeframe_partitions
             ON asset_both.asset = assets_timeframe_partitions.asset
         WHERE asset.is_seasonal
         """
    for row in DuckDB.query(connection, find_assets_partitions_query)
        for year in milestone_years
            graph[row.asset].timeframe_partitions[year] = _parse_rp_partition(
                Val(Symbol(row.specification)),
                row.partition,
                1:timeframe.num_periods,
            )
        end
    end

    _df =
        DuckDB.execute(
            connection,
            "SELECT asset, commission_year, profile_type, year, rep_period, value
            FROM assets_profiles
            JOIN profiles_rep_periods
            ON assets_profiles.profile_name=profiles_rep_periods.profile_name",
        ) |> DataFrame

    gp = DataFrames.groupby(_df, [:asset, :commission_year, :profile_type, :year, :rep_period])

    for ((asset, commission_year, profile_type, year, rep_period), df) in pairs(gp)
        profiles = graph[asset].rep_periods_profiles
        if !haskey(profiles, year)
            profiles[year] = Dict{Int,Dict{Tuple{Symbol,Int},Vector{Float64}}}()
        end
        if !haskey(profiles[year], commission_year)
            profiles[year][commission_year] = Dict{Tuple{Symbol,Int},Vector{Float64}}()
        end
        profiles[year][commission_year][(profile_type, rep_period)] = df.value
    end

    _df = TulipaIO.get_table(connection, "profiles_rep_periods")
    for flow_profile_row in TulipaIO.get_table(Val(:raw), connection, "flows_profiles")
        gp = DataFrames.groupby(
            filter(:profile_name => ==(flow_profile_row.profile_name), _df; view = true),
            [:rep_period, :year];
        )
        for ((rep_period, year), df) in pairs(gp)
            profiles =
                graph[flow_profile_row.from_asset, flow_profile_row.to_asset].rep_periods_profiles
            if !haskey(profiles, year)
                profiles[year] = Dict{Tuple{Symbol,Int},Vector{Float64}}()
            end
            profiles[year][(flow_profile_row.profile_type, rep_period)] = df.value
        end
    end

    _df = TulipaIO.get_table(connection, "profiles_timeframe")
    for asset_profile_row in TulipaIO.get_table(Val(:raw), connection, "assets_timeframe_profiles") # row = asset, profile_type, profile_name
        gp = DataFrames.groupby(
            filter( # Filter
                [:profile_name, :year] =>
                    (name, year) ->
                        name == asset_profile_row.profile_name &&
                            year == asset_profile_row.commission_year,
                _df;
                view = true,
            ),
            [:year],
        )
        for ((year,), df) in pairs(gp)
            profiles = graph[asset_profile_row.asset].timeframe_profiles
            if !haskey(profiles, year)
                profiles[year] = Dict{Int,Dict{String,Vector{Float64}}}()
                profiles[year][year] = Dict{String,Vector{Float64}}()
            end
            profiles[year][year][asset_profile_row.profile_type] = df.value
        end
    end

    return graph, representative_periods, timeframe, groups, years
end

function get_schema(tablename)
    if haskey(schema_per_table_name, tablename)
        return schema_per_table_name[tablename]
    else
        error("No implicit schema for table named $tablename")
    end
end

function _check_if_table_exist(connection, table_name)
    schema = get_schema(table_name)

    existence_query = DBInterface.execute(
        connection,
        "SELECT table_name FROM information_schema.tables WHERE table_name = '$table_name'",
    )
    if length(collect(existence_query)) == 0
        columns_in_table = join(("$col $col_type" for (col, col_type) in schema), ",")
        create_table_query =
            DuckDB.query(connection, "CREATE TABLE $table_name ($columns_in_table)")
    end
    return nothing
end

"""
    save_solution_to_file(output_folder, energy_problem)

Saves the solution from `energy_problem` in CSV files inside `output_file`.
"""
function save_solution_to_file(output_folder, energy_problem::EnergyProblem)
    if !energy_problem.solved
        error("The energy_problem has not been solved yet.")
    end
    save_solution_to_file(
        output_folder,
        energy_problem.graph,
        energy_problem.dataframes,
        energy_problem.solution,
    )
end

"""
    save_solution_to_file(output_file, graph, solution)

Saves the solution in CSV files inside `output_folder`.

The following files are created:

  - `assets-investment.csv`: The format of each row is `a,v,p*v`, where `a` is the asset name,
    `v` is the corresponding asset investment value, and `p` is the corresponding
    capacity value. Only investable assets are included.
  - `assets-investments-energy.csv`: The format of each row is `a,v,p*v`, where `a` is the asset name,
    `v` is the corresponding asset investment value on energy, and `p` is the corresponding
    energy capacity value. Only investable assets with a `storage_method_energy` set to `true` are included.
  - `flows-investment.csv`: Similar to `assets-investment.csv`, but for flows.
  - `flows.csv`: The value of each flow, per `(from, to)` flow, `rp` representative period
    and `timestep`. Since the flow is in power, the value at a timestep is equal to the value
    at the corresponding time block, i.e., if flow[1:3] = 30, then flow[1] = flow[2] = flow[3] = 30.
  - `storage-level.csv`: The value of each storage level, per `asset`, `rp` representative period,
    and `timestep`. Since the storage level is in energy, the value at a timestep is a
    proportional fraction of the value at the corresponding time block, i.e., if level[1:3] = 30,
    then level[1] = level[2] = level[3] = 10.
"""
function save_solution_to_file(output_folder, graph, dataframes, solution)
    output_file = joinpath(output_folder, "assets-investments.csv")
    output_table = DataFrame(;
        asset = String[],
        year = Int[],
        InstalUnits = Float64[],
        InstalCap_MW = Float64[],
    )

    for ((y, a), investment) in solution.assets_investment
        capacity = graph[a].capacity
        push!(output_table, (a, y, investment, capacity * investment))
    end
    CSV.write(output_file, output_table)

    output_file = joinpath(output_folder, "assets-investments-energy.csv")
    output_table = DataFrame(;
        asset = String[],
        year = Int[],
        InstalEnergyUnits = Float64[],
        InstalEnergyCap_MWh = Float64[],
    )

    for ((y, a), energy_units_investmented) in solution.assets_investment_energy
        energy_capacity = graph[a].capacity_storage_energy
        push!(
            output_table,
            (a, y, energy_units_investmented, energy_capacity * energy_units_investmented),
        )
    end
    CSV.write(output_file, output_table)

    output_file = joinpath(output_folder, "flows-investments.csv")
    output_table = DataFrame(;
        from_asset = String[],
        to_asset = String[],
        year = Int[],
        InstalUnits = Float64[],
        InstalCap_MW = Float64[],
    )

    for ((y, (u, v)), investment) in solution.flows_investment
        capacity = graph[u, v].capacity
        push!(output_table, (u, v, y, investment, capacity * investment))
    end
    CSV.write(output_file, output_table)

    #=
    In both cases below, we select the relevant columns from the existing dataframes,
    then, we append the solution column.
    After that, we transform and flatten, by rows, the time block values into a long version.
    I.e., if a row shows `timesteps_block = 3:5` and `value = 30`, then we transform into
    three rows with values `timestep = [3, 4, 5]` and `value` equal to 30 / 3 for storage,
    or 30 for flows.
    =#

    # TODO: Fix all output
    # output_file = joinpath(output_folder, "flows.csv")
    # output_table = DataFrames.select(
    #     dataframes[:flows],
    #     :from,
    #     :to,
    #     :year,
    #     :rep_period,
    #     :timesteps_block => :timestep,
    # )
    # output_table.value = solution.flow
    # output_table = DataFrames.flatten(
    #     DataFrames.transform(
    #         output_table,
    #         [:timestep, :value] =>
    #             DataFrames.ByRow(
    #                 (timesteps_block, value) -> begin # transform each row using these two columns
    #                     n = length(timesteps_block)
    #                     (timesteps_block, Iterators.repeated(value, n)) # e.g., (3:5, [30, 30, 30])
    #                 end,
    #             ) => [:timestep, :value],
    #     ),
    #     [:timestep, :value], # flatten, e.g., [(3, 30), (4, 30), (5, 30)]
    # )
    # output_table |> CSV.write(output_file)

    # output_file = joinpath(output_folder, "storage-level-intra-rp.csv")
    # output_table = DataFrames.select(
    #     dataframes[:storage_level_intra_rp],
    #     :asset,
    #     :rep_period,
    #     :timesteps_block => :timestep,
    # )
    # output_table.value = solution.storage_level_intra_rp
    # if !isempty(output_table.asset)
    #     output_table = DataFrames.combine(DataFrames.groupby(output_table, :asset)) do subgroup
    #         _check_initial_storage_level!(subgroup, graph)
    #         _interpolate_storage_level!(subgroup, :timestep)
    #     end
    # end
    # output_table |> CSV.write(output_file)

    # output_file = joinpath(output_folder, "storage-level-inter-rp.csv")
    # output_table =
    #     DataFrames.select(dataframes[:storage_level_inter_rp], :asset, :periods_block => :period)
    # output_table.value = solution.storage_level_inter_rp
    # if !isempty(output_table.asset)
    #     output_table = DataFrames.combine(DataFrames.groupby(output_table, :asset)) do subgroup
    #         _check_initial_storage_level!(subgroup, graph)
    #         _interpolate_storage_level!(subgroup, :period)
    #     end
    # end
    # output_table |> CSV.write(output_file)
    #
    # output_file = joinpath(output_folder, "max-energy-inter-rp.csv")
    # output_table =
    #     DataFrames.select(dataframes[:max_energy_inter_rp], :asset, :periods_block => :period)
    # output_table.value = solution.max_energy_inter_rp
    # output_table |> CSV.write(output_file)
    #
    # output_file = joinpath(output_folder, "min-energy-inter-rp.csv")
    # output_table =
    #     DataFrames.select(dataframes[:min_energy_inter_rp], :asset, :periods_block => :period)
    # output_table.value = solution.min_energy_inter_rp
    # output_table |> CSV.write(output_file)

    return
end

"""
    _check_initial_storage_level!(df)

Determine the starting value for the initial storage level for interpolating the storage level.
If there is no initial storage level given, we will use the final storage level.
Otherwise, we use the given initial storage level.
"""
function _check_initial_storage_level!(df, graph)
    initial_storage_level_dict = graph[unique(df.asset)[1]].initial_storage_level
    for (_, initial_storage_level) in initial_storage_level_dict
        if ismissing(initial_storage_level)
            df[!, :processed_value] = [df.value[end]; df[1:end-1, :value]]
        else
            df[!, :processed_value] = [initial_storage_level; df[1:end-1, :value]]
        end
    end
end

"""
    _interpolate_storage_level!(df, time_column::Symbol)

Transform the storage level dataframe from grouped timesteps or periods to incremental ones by interpolation.
The starting value is the value of the previous grouped timesteps or periods or the initial value.
The ending value is the value for the grouped timesteps or periods.
"""
function _interpolate_storage_level!(df, time_column)
    DataFrames.flatten(
        DataFrames.transform(
            df,
            [time_column, :value, :processed_value] =>
                DataFrames.ByRow(
                    (period, value, start_value) -> begin
                        n = length(period)
                        interpolated_values = range(start_value; stop = value, length = n + 1)
                        (period, value, interpolated_values[2:end])
                    end,
                ) => [time_column, :value, :processed_value],
        ),
        [time_column, :processed_value],
    )
end

"""
    _parse_rp_partition(Val(specification), timestep_string, rp_timesteps)

Parses the `timestep_string` according to the specification.
The representative period timesteps (`rp_timesteps`) might not be used in the computation,
but it will be used for validation.

The specification defines what is expected from the `timestep_string`:

  - `:uniform`: The `timestep_string` should be a single number indicating the duration of
    each block. Examples: "3", "4", "1".
  - `:explicit`: The `timestep_string` should be a semicolon-separated list of integers.
    Each integer is a duration of a block. Examples: "3;3;3;3", "4;4;4",
    "1;1;1;1;1;1;1;1;1;1;1;1", and "3;3;4;2".
  - `:math`: The `timestep_string` should be an expression of the form `NxD+NxD…`, where `D`
    is the duration of the block and `N` is the number of blocks. Examples: "4x3", "3x4",
    "12x1", and "2x3+1x4+1x2".

The generated blocks will be ranges (`a:b`). The first block starts at `1`, and the last
block ends at `length(rp_timesteps)`.

The following table summarizes the formats for a `rp_timesteps = 1:12`:

| Output                | :uniform | :explicit               | :math       |
|:--------------------- |:-------- |:----------------------- |:----------- |
| 1:3, 4:6, 7:9, 10:12  | 3        | 3;3;3;3                 | 4x3         |
| 1:4, 5:8, 9:12        | 4        | 4;4;4                   | 3x4         |
| 1:1, 2:2, …, 12:12    | 1        | 1;1;1;1;1;1;1;1;1;1;1;1 | 12x1        |
| 1:3, 4:6, 7:10, 11:12 | NA       | 3;3;4;2                 | 2x3+1x4+1x2 |

## Examples

```jldoctest
using TulipaEnergyModel
TulipaEnergyModel._parse_rp_partition(Val(:uniform), "3", 1:12)

# output

4-element Vector{UnitRange{Int64}}:
 1:3
 4:6
 7:9
 10:12
```

```jldoctest
using TulipaEnergyModel
TulipaEnergyModel._parse_rp_partition(Val(:explicit), "4;4;4", 1:12)

# output

3-element Vector{UnitRange{Int64}}:
 1:4
 5:8
 9:12
```

```jldoctest
using TulipaEnergyModel
TulipaEnergyModel._parse_rp_partition(Val(:math), "2x3+1x4+1x2", 1:12)

# output

4-element Vector{UnitRange{Int64}}:
 1:3
 4:6
 7:10
 11:12
```
"""
function _parse_rp_partition end

function _parse_rp_partition(::Val{:uniform}, timestep_string, rp_timesteps)
    duration = parse(Int, timestep_string)
    partition = [i:i+duration-1 for i in 1:duration:length(rp_timesteps)]
    @assert partition[end][end] == length(rp_timesteps)
    return partition
end

function _parse_rp_partition(::Val{:explicit}, timestep_string, rp_timesteps)
    partition = UnitRange{Int}[]
    block_begin = 1
    block_lengths = parse.(Int, split(timestep_string, ";"))
    for block_length in block_lengths
        block_end = block_begin + block_length - 1
        push!(partition, block_begin:block_end)
        block_begin = block_end + 1
    end
    @assert block_begin - 1 == length(rp_timesteps)
    return partition
end

function _parse_rp_partition(::Val{:math}, timestep_string, rp_timesteps)
    partition = UnitRange{Int}[]
    block_begin = 1
    block_instruction = split(timestep_string, "+")
    for R in block_instruction
        num, len = parse.(Int, split(R, "x"))
        for _ in 1:num
            block = (1:len) .+ (block_begin - 1)
            block_begin += len
            push!(partition, block)
        end
    end
    @assert block_begin - 1 == length(rp_timesteps)
    return partition
end

"""
    compute_assets_partitions!(partitions, df, a, representative_periods)

Parses the time blocks in the DataFrame `df` for the asset `a` and every
representative period in the `timesteps_per_rp` dictionary, modifying the
input `partitions`.

`partitions` must be a dictionary indexed by the representative periods,
possibly empty.

`timesteps_per_rp` must be a dictionary indexed by `rep_period` and its values are the
timesteps of that `rep_period`.

To obtain the partitions, the columns `specification` and `partition` from `df`
are passed to the function [`_parse_rp_partition`](@ref).
"""
function compute_assets_partitions!(partitions, df, a, representative_periods)
    for (rep_period_index, rep_period) in enumerate(representative_periods)
        # Look for index in df that matches this asset and rep_period
        j = findfirst((df.asset .== a) .& (df.rep_period .== rep_period_index))
        partitions[rep_period_index] = if j === nothing
            N = length(rep_period.timesteps)
            # If there is no time block specification, use default of 1
            [k:k for k in 1:N]
        else
            _parse_rp_partition(
                Val(Symbol(df[j, :specification])),
                df[j, :partition],
                rep_period.timesteps,
            )
        end
    end
end

"""
    compute_flows_partitions!(partitions, df, u, v, representative_periods)

Parses the time blocks in the DataFrame `df` for the flow `(u, v)` and every
representative period in the `timesteps_per_rp` dictionary, modifying the
input `partitions`.

`partitions` must be a dictionary indexed by the representative periods,
possibly empty.

`timesteps_per_rp` must be a dictionary indexed by `rep_period` and its values are the
timesteps of that `rep_period`.

To obtain the partitions, the columns `specification` and `partition` from `df`
are passed to the function [`_parse_rp_partition`](@ref).
"""
function compute_flows_partitions!(partitions, df, u, v, representative_periods)
    for (rep_period_index, rep_period) in enumerate(representative_periods)
        # Look for index in df that matches this asset and rep_period
        j = findfirst(
            (df.from_asset .== u) .& (df.to_asset .== v) .& (df.rep_period .== rep_period_index),
        )
        partitions[rep_period_index] = if j === nothing
            N = length(rep_period.timesteps)
            # If there is no time block specification, use default of 1
            [k:k for k in 1:N]
        else
            _parse_rp_partition(
                Val(Symbol(df[j, :specification])),
                df[j, :partition],
                rep_period.timesteps,
            )
        end
    end
end
