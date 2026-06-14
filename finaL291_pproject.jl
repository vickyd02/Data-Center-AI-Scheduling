using JuMP
using HiGHS
using CSV
using DataFrames
using XLSX

# File paths
stanford_file = "/Users/vicky/Downloads/Energy 291 Optimization/291 Optimization Project/Stanford CEF Data Request for Dinov and Blust.xlsx"
nrel_file     = "/Users/vicky/Downloads/Energy 291 Optimization/291 Optimization Project/Cambium24_Workbook.xlsx"
job_csv       = "/Users/vicky/Downloads/Energy 291 Optimization/291 Optimization Project/pai_job_table.csv"
task_csv      = "/Users/vicky/Downloads/Energy 291 Optimization/291 Optimization Project/pai_task_table.csv"
sensor_csv    = "/Users/vicky/Downloads/Energy 291 Optimization/291 Optimization Project/pai_sensor_table.csv"

# ------------------------------------------------------------------------------
# STEP 1: EMPIRICAL DATA PROCESSING
# ------------------------------------------------------------------------------
function clean_to_float_vector(raw_matrix)
    flat_vector = vec(raw_matrix)
    return [typeof(x) <: Number ? Float64(x) : parse(Float64, strip(string(x))) for x in flat_vector]
end

function load_annual_data(stanford_path, nrel_path)
    println("Loading Stanford CEF and NREL Cambium data...")
    xf_stanford = XLSX.readxlsx(stanford_path)
    sheet_stanford = xf_stanford["Sheet1"]

    campus_chw_demand = max.(clean_to_float_vector(sheet_stanford["E6:E8765"]), 0.0) 
    campus_hw_demand  = max.(clean_to_float_vector(sheet_stanford["H6:H8765"]), 0.0)
    prices_8760       = clean_to_float_vector(sheet_stanford["Q6:Q8765"])  
    chw_tes_hist      = clean_to_float_vector(sheet_stanford["O6:O8765"])  
    hw_tes_hist       = clean_to_float_vector(sheet_stanford["M6:M8765"])  

    xf_nrel = XLSX.readxlsx(nrel_path)
    sheet_nrel = xf_nrel["Levelized LRMER"]
    lrmer_8760 = clean_to_float_vector(sheet_nrel["F350:F9109"])  

    return campus_chw_demand, campus_hw_demand, prices_8760, lrmer_8760, chw_tes_hist, hw_tes_hist
end

# ------------------------------------------------------------------------------
# STEP 2: SYSTEM BOUNDARIES & CONSTANTS
# ------------------------------------------------------------------------------
const max_ai_capacity_mw  = 6.0
const ai_daily_target_mwh = 100.0
const pue                 = 1.15
const mw_to_tons          = 284.345   

const max_delay_hours     = 120.0
const max_backlog_mwh     = max_delay_hours * ai_daily_target_mwh / 24.0 # 500 MWh Queue

const chw_tank_max_soc  = 90_000.0   
const chw_tank_min_soc  = 0.0        
const hw_tank_max_soc   = 600.0      
const hw_tank_min_soc   = 0.0        
const chw_tank_max_flow = 16564.0    
const hw_tank_max_flow  = 96.435     

const hrc_max_tons            = 2_500.0
const hrc_min_tons            = 2_000.0     
const hrc_mw_per_ton_cooling  = 0.0013216   
const hrc_mmbtu_per_ton_cool  = 0.01627     

const conv_chiller_cop      = 5.5           
const conv_chiller_mw_per_ton = 3.517 / (conv_chiller_cop * 1000.0)
const boiler_cost_per_mmbtu = 10.0 / 0.85   
const boiler_emissions_per_mmbtu = 53.06    
const cloud_outsource_cost_per_mwh = 1200.0 
const cloud_emissions_per_mwh = 450.0

const cost_normalizer   = 3_000.0
const carbon_normalizer = 1.5
const speed_normalizer  = 300.0
const w_cost   = 0.35
const w_carbon = 0.30
const w_speed  = 0.35

# ------------------------------------------------------------------------------
# STEP 3: RAW AI DEMAND
# ------------------------------------------------------------------------------
function build_dynamic_alibaba_demand(job_csv, task_csv, sensor_csv, target_annual_mwh)
    println("Parsing dynamic Alibaba cluster trace...")
    jobs    = CSV.read(job_csv,    DataFrame, header=["job_name","inst_id","user","status","start_time","end_time"])
    tasks   = CSV.read(task_csv,   DataFrame, header=["job_name","task_name","inst_num","status","start_time","end_time","plan_cpu","plan_mem","plan_gpu","gpu_type"])
    sensors = CSV.read(sensor_csv, DataFrame, header=["job_name","task_name","worker_name","inst_id","machine","gpu_name","cpu_usage","gpu_wrk_util","avg_mem","max_mem","avg_gpu_wrk_mem","max_gpu_wrk_mem","read","write","read_count","write_count"])

    df = innerjoin(tasks, sensors, on=[:job_name, :task_name], makeunique=true)
    df = innerjoin(df, jobs, on=:job_name, makeunique=true)
    
    dropmissing!(df, [:status, :start_time, :end_time, :cpu_usage, :gpu_wrk_util])
    filter!(row -> coalesce(row.status == "Terminated", false), df)

    df.power_mw     = ((df.cpu_usage ./ 100 .* 30.0) .+ (df.gpu_wrk_util ./ 100 .* 400.0)) ./ 1_000_000.0
    df.duration_hrs = (df.end_time .- df.start_time) ./ 3600.0
    df.energy_mwh   = df.power_mw .* df.duration_hrs

    min_start_time  = minimum(df.start_time)
    df.hour_index   = floor.(Int, (df.start_time .- min_start_time) ./ 3600.0) .+ 1

    max_hour = maximum(df.hour_index)
    trace_hourly_demand = zeros(Float64, max_hour)
    
    for row in eachrow(df)
        if !ismissing(row.hour_index) && !ismissing(row.energy_mwh) && row.hour_index > 0 && row.energy_mwh > 0
            trace_hourly_demand[row.hour_index] += row.energy_mwh
        end
    end

    annual_raw_demand = zeros(Float64, 8760)
    for t in 1:8760
        trace_t = mod1(t, max_hour)
        annual_raw_demand[t] = trace_hourly_demand[trace_t]
    end

    scale_factor = target_annual_mwh / sum(annual_raw_demand)
    return annual_raw_demand .* scale_factor
end

# ------------------------------------------------------------------------------
# STEP 4: 48-HOUR ROLLING MILP ENGINE (includes baseline too)
# ------------------------------------------------------------------------------
function optimize_window(init_chw, init_hw, init_backlog,
                         prices, chw_demand, hw_demand, lrmer, ai_arrivals, baseline_mode=false)
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    
    window_len = length(prices) #should be 48
    T = 1:window_len

    @variable(model, 0 <= ai_compute[t in T] <= max_ai_capacity_mw)
    
    # Baseline Mode (0 Queueing Allowed) vs coordinate mode (Queueing Allowed)
    if baseline_mode
        @variable(model, backlog[t in T] == 0.0) 
    else
        @variable(model, 0 <= backlog[t in T] <= max_backlog_mwh)
    end
    
    @variable(model, 0 <= cloud_outsource[t in T]) 

    @variable(model, chw_tank_min_soc <= chw_tank[t in T] <= chw_tank_max_soc)
    @variable(model, 0 <= hrc_cooling[t in T]    <= hrc_max_tons)
    @variable(model, hrc_on[t in T], Bin)
    @variable(model, 0 <= conv_chiller[t in T])  

    @variable(model, hw_tank_min_soc <= hw_tank[t in T] <= hw_tank_max_soc)
    @variable(model, hrc_heating[t in T] >= 0)
    @variable(model, 0 <= boiler[t in T])        
    @variable(model, grid_draw[t in T] >= 0)

    # HRC Turndown 
    M_cool = hrc_max_tons
    for t in T
        @constraint(model, hrc_cooling[t] >= hrc_min_tons * hrc_on[t])
        @constraint(model, hrc_cooling[t] <= M_cool * hrc_on[t])
        @constraint(model, hrc_heating[t] == hrc_cooling[t] * hrc_mmbtu_per_ton_cool)
    end

    # AI Workload Queue 
    @constraint(model, backlog[1] == init_backlog + ai_arrivals[1] - ai_compute[1] - cloud_outsource[1])
    for t in 2:window_len
        @constraint(model, backlog[t] == backlog[t-1] + ai_arrivals[t] - ai_compute[t] - cloud_outsource[t])
    end

    # CHW & HW Tank Balances
    for t in T
        ai_cooling_load = ai_compute[t] * mw_to_tons * pue  
        prev_chw = (t == 1) ? init_chw : chw_tank[t-1]
        prev_hw  = (t == 1) ? init_hw  : hw_tank[t-1]

        @constraint(model, chw_tank[t] == prev_chw + hrc_cooling[t] + conv_chiller[t] - chw_demand[t] - ai_cooling_load)
        @constraint(model, chw_tank[t] - prev_chw <=  chw_tank_max_flow)
        @constraint(model, prev_chw - chw_tank[t] <=  chw_tank_max_flow)

        @constraint(model, hw_tank[t] == prev_hw + hrc_heating[t] + boiler[t] - hw_demand[t])
        @constraint(model, hw_tank[t] - prev_hw <=  hw_tank_max_flow)
        @constraint(model, prev_hw - hw_tank[t] <=  hw_tank_max_flow)
    end

    # Electric Power Balance
    for t in T
        hrc_elec  = hrc_cooling[t] * hrc_mw_per_ton_cooling
        conv_elec = conv_chiller[t] * conv_chiller_mw_per_ton
        @constraint(model, grid_draw[t] == ai_compute[t] + hrc_elec + conv_elec)
    end

    @expression(model, TotalCost, sum(grid_draw[t]*prices[t] + boiler[t]*boiler_cost_per_mmbtu + cloud_outsource[t]*cloud_outsource_cost_per_mwh for t in T))
    @expression(model, TotalCarbon, (sum(grid_draw[t]*lrmer[t] + boiler[t]*boiler_emissions_per_mmbtu + cloud_outsource[t]*cloud_emissions_per_mwh for t in T)) / 1000.0)
    @expression(model, TotalBacklog, sum(backlog[t] for t in T))

    @objective(model, Min,
        w_cost   * (TotalCost   / cost_normalizer)   +
        w_carbon * (TotalCarbon / carbon_normalizer)  +
        w_speed  * (TotalBacklog / speed_normalizer)
    )

    optimize!(model)
    status = termination_status(model)

    # hourly arrays for Cost and Carbon before returning
    if status == MOI.OPTIMAL || status == MOI.LOCALLY_SOLVED
        v_comp  = value.(ai_compute)[1:24]
        v_back  = value.(backlog)[1:24]
        v_cloud = value.(cloud_outsource)[1:24]
        v_grid  = value.(grid_draw)[1:24]
        v_hrc   = value.(hrc_cooling)[1:24]
        v_boil  = value.(boiler)[1:24]

        # cost and carbon for exactly hours 1-24
        h_cost = (v_grid .* prices[1:24]) .+ (v_boil .* boiler_cost_per_mmbtu) .+ (v_cloud .* cloud_outsource_cost_per_mwh)
        h_carb = (v_grid .* lrmer[1:24] .+ v_boil .* boiler_emissions_per_mmbtu .+ v_cloud .* cloud_emissions_per_mwh) ./ 1000.0

        return (value(chw_tank[24]), value(hw_tank[24]), value(backlog[24]),
                v_comp, v_back, v_cloud, v_grid, v_hrc, h_cost, h_carb, status)
    else
        return (init_chw, init_hw, init_backlog, 
                zeros(24), zeros(24), zeros(24), zeros(24), zeros(24), zeros(24), zeros(24), status)
    end
end 

# ------------------------------------------------------------------------------
# STEP 5: ORCHESTRATION & LOGGING LOOP
# ------------------------------------------------------------------------------
annual_target_mwh = 36_500.0
dyn_ai_8760 = build_dynamic_alibaba_demand(job_csv, task_csv, sensor_csv, annual_target_mwh)
campus_chw_8760, campus_hw_8760, prices_8760, lrmer_8760, chw_tes_hist, hw_tes_hist = load_annual_data(stanford_file, nrel_file)

# arrays for 48 window on last day (day 365)
prices_pad = vcat(prices_8760, prices_8760[1:24])
chw_pad    = vcat(campus_chw_8760, campus_chw_8760[1:24])
hw_pad     = vcat(campus_hw_8760, campus_hw_8760[1:24])
lrmer_pad  = vcat(lrmer_8760, lrmer_8760[1:24])
ai_pad     = vcat(dyn_ai_8760, dyn_ai_8760[1:24])

function run_annual_sim(baseline_mode::Bool)
    println("\nExecuting Simulation... (Baseline Mode: $baseline_mode)")
    current_chw_soc = chw_tes_hist[1]   
    current_hw_soc  = hw_tes_hist[1]    
    current_backlog = 0.0
    
    # initialize 8760 data loggers
    log_compute = zeros(8760); log_backlog = zeros(8760); log_cloud  = zeros(8760)
    log_grid    = zeros(8760); log_hrc     = zeros(8760)
    log_cost    = zeros(8760); log_carbon  = zeros(8760)

    for day in 1:365
        h_start = (day - 1) * 24 + 1
        h_end   = h_start + 47 # 48 Hour Window
        
        d_prices = prices_pad[h_start:h_end]
        d_chw    = chw_pad[h_start:h_end]
        d_hw     = hw_pad[h_start:h_end]
        d_lrmer  = lrmer_pad[h_start:h_end]
        d_ai     = ai_pad[h_start:h_end]

        end_chw, end_hw, end_backlog, h_comp, h_back, h_cloud, h_grid, h_hrc, h_cost, h_carb, status =
            optimize_window(current_chw_soc, current_hw_soc, current_backlog, d_prices, d_chw, d_hw, d_lrmer, d_ai, baseline_mode)

        if status == MOI.OPTIMAL || status == MOI.LOCALLY_SOLVED
            current_chw_soc = end_chw; current_hw_soc = end_hw; current_backlog = end_backlog
            
            # 24-hour block saved to the global logger
            log_compute[h_start:(h_start+23)] = h_comp
            log_backlog[h_start:(h_start+23)] = h_back
            log_cloud[h_start:(h_start+23)]   = h_cloud
            log_grid[h_start:(h_start+23)]    = h_grid
            log_hrc[h_start:(h_start+23)]     = h_hrc
            log_cost[h_start:(h_start+23)]    = h_cost
            log_carbon[h_start:(h_start+23)]  = h_carb
        else
            println("⚠  Solver Failed at Day $day. Status: $status")
        end
    end
    
    # final output
    df_results = DataFrame(
        Hour = 1:8760,
        AI_Arrivals_MWh = dyn_ai_8760,
        Local_Compute_MW = log_compute,
        Queue_Backlog_MWh = log_backlog,
        Cloud_Outsource_MWh = log_cloud,
        Total_Grid_Draw_MW = log_grid,
        HRC_Cooling_Tons = log_hrc,
        Hourly_Cost_USD = log_cost,          
        Hourly_Carbon_MT = log_carbon     
    )
    return df_results
end

# simulation
df_baseline = run_annual_sim(true)   # Control Group (No Queueing)
df_smart    = run_annual_sim(false)  # Optimized coordinated model

# export to CSV
CSV.write("/Users/vicky/Downloads/Energy 291 Optimization/291 Optimization Project/Baseline_Results_8760.csv", df_baseline)
CSV.write("/Users/vicky/Downloads/Energy 291 Optimization/291 Optimization Project/Smart_Optimized_Results_8760.csv", df_smart)

println("\n======================================================================")
println("SIMULATIONS COMPLETE.")
println("1. 8760-hour logs for both Baseline and Smart modes saved to CSV.")
println("2. You can now plot 'Queue_Backlog_MWh' to show the shock absorber effect.")
println("3. Compare 'Cloud_Outsource_MWh' totals to prove the cost savings of the queue.")
println("======================================================================")
