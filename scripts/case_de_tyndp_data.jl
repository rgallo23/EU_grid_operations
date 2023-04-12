# Script to test the European grid
using PowerModels; const _PM = PowerModels
using PowerModelsACDC; const _PMACDC = PowerModelsACDC
using EU_grid_operations; const _EUGO = EU_grid_operations
using Gurobi
using JSON
using PlotlyJS


## Import required functions - Some of them in later stages.....
import Ipopt
using Plots
import Memento
import JuMP
import Gurobi  # needs startvalues for all variables!
import JSON
import CBAOPF
import DataFrames; const _DF = DataFrames
import CSV
import ExcelFiles; const _EF = ExcelFiles
import Feather
using XLSX
using Statistics
using Clustering
using StatsBase
import StatsPlots

######### DEFINE INPUT PARAMETERS
scenario = "GA2030"
climate_year = "2007"
load_data = true
use_case = "de_hvdc_backbone"
only_hvdc_case = false
links = Dict("Ultranet" => [], "Suedostlink" => [] , "Suedlink" => [])
zone = "DE00"
output_base = "DE"
output_cba = "DE_HVDC"
number_of_clusters = 20
number_of_hours_rd = 5
hour_start = 1
hour_end = 8760
############ LOAD EU grid data
include("batch_opf.jl")
file = "./data_sources/European_grid.json"
output_file_name = joinpath("results", join([use_case,"_",scenario,"_", climate_year]))
output_file_name_un = joinpath("results", join([use_case,"_",scenario,"_", climate_year, "_un"]))
gurobi = Gurobi.Optimizer
EU_grid = _PM.parse_file(file)
_PMACDC.process_additional_data!(EU_grid)
_EUGO.add_load_and_pst_properties!(EU_grid)

#### LOAD TYNDP SCENARIO DATA ##########
if load_data == true
    zonal_result, zonal_input, scenario_data = _EUGO.load_results(scenario, climate_year) # Import zonal results
    ntcs, zones, arcs, tyndp_capacity, tyndp_demand, gen_types, gen_costs, emission_factor, inertia_constants, start_up_cost, node_positions = _EUGO.get_grid_data(scenario) # import zonal input (mainly used for cost data)
    pv, wind_onshore, wind_offshore = _EUGO.load_res_data()
end

print("ALL FILES LOADED", "\n")
print("----------------------","\n")
####################

# map EU-Grid zones to TYNDP model zones
zone_mapping = _EUGO.map_zones()

# Scale generation capacity based on TYNDP data
_EUGO.scale_generation!(tyndp_capacity, EU_grid, scenario, climate_year, zone_mapping)

# For high impedance lines, set power rating to what is physically possible -> otherwise it leads to infeasibilities around XB lines
_EUGO.fix_data!(EU_grid)

# Isolate zone: input is vector of strings
zone_grid = _EUGO.isolate_zones(EU_grid, ["DE"]; border_slack = 0.02)

# create RES time series based on the TYNDP model for 
# (1) all zones, e.g.  create_res_time_series(wind_onshore, wind_offshore, pv, zone_mapping) 
# (2) a specified zone, e.g. create_res_time_series(wind_onshore, wind_offshore, pv, zone_mapping; zone = "DE")
timeseries_data = _EUGO.create_res_and_demand_time_series(wind_onshore, wind_offshore, pv, scenario_data, zone_mapping; zone = "DE")

# Determine hourly cross-border flows and add them to time series data
push!(timeseries_data, "xb_flows" => _EUGO.get_xb_flows(zone_grid, zonal_result, zonal_input, zone_mapping)) 

# Determine demand response potential and add them to zone_grid. Default cost value = 140 Euro / MWh, can be changed with get_demand_reponse!(...; cost = xx)
_EUGO.get_demand_reponse!(zone_grid, zonal_input, zone_mapping, timeseries_data)

for (b, branch) in zone_grid["branch"]
    branch["angmin"] = -pi
    branch["angmax"] = pi
    # if branch["rate_a"] == 50
    #     branch["rate_a"] = 20
    # end
end

#####  Adding Ultranet MTDC

# AC bus loactions: A-North: Emden Ost -> Osterath, Ultranet: Osterath -> Phillipsburg
# Rating: 2 GW, 525 kV
# Emden Ost: lat: 53.355716, lon: 7.244506
# Osterath: lat: 51.26027036315153, lon: 6.627044464872153
# Phillipsburg: lat: 49.255371 lon: 8.438422

power_rating = 20.0
dc_voltage = 525

zone_grid_un = deepcopy(zone_grid)

# Conenction Emden Ost, Osterath first
# First Step: ADD dc bus & converter in Emden Ost
zone_grid_un, dc_bus_idx_em = _EUGO.add_dc_bus!(zone_grid_un, dc_voltage; lat = 53.355716, lon = 7.244506)
ac_bus_idx = _EUGO.find_closest_bus(zone_grid_un, 53.355716, 7.244506)
_EUGO.add_converter!(zone_grid_un, ac_bus_idx, dc_bus_idx_em, power_rating)
# Second step: ADD dc bus & converter in Osterath and DC branch Emden -> Osterath
zone_grid_un, dc_bus_idx_os = _EUGO.add_dc_bus!(zone_grid_un, dc_voltage; lat = 51.26027036315153, lon = 6.627044464872153)
ac_bus_idx = _EUGO.find_closest_bus(zone_grid_un, 51.26027036315153, 6.627044464872153)
_EUGO.add_converter!(zone_grid_un, ac_bus_idx, dc_bus_idx_os, power_rating)
_EUGO.add_dc_branch!(zone_grid_un, dc_bus_idx_em, dc_bus_idx_os, power_rating)
# Third step add dc bus and converter in Phillipsburg & branch Osterath - Phillipsburg
zone_grid_un, dc_bus_idx_ph = _EUGO.add_dc_bus!(zone_grid_un, dc_voltage; lat = 49.255371, lon = 8.438422)
ac_bus_idx = _EUGO.find_closest_bus(zone_grid_un, 49.255371, 8.438422)
_EUGO.add_converter!(zone_grid_un, ac_bus_idx, dc_bus_idx_ph, power_rating)
_EUGO.add_dc_branch!(zone_grid_un, dc_bus_idx_os, dc_bus_idx_ph, power_rating)


########### Sued link:
# Brunsbuettel: 53.9160355330674, 9.235429411946734
# Grossgartach: 49.1424721420109, 9.149063227242355
zone_grid_un, dc_bus_idx_bb = _EUGO.add_dc_bus!(zone_grid_un, dc_voltage; lat = 53.9160355330674, lon = 9.235429411946734)
ac_bus_idx = _EUGO.find_closest_bus(zone_grid_un, 53.9160355330674, 9.235429411946734)
_EUGO.add_converter!(zone_grid_un, ac_bus_idx, dc_bus_idx_bb, power_rating)
zone_grid_un, dc_bus_idx_gg = _EUGO.add_dc_bus!(zone_grid_un, dc_voltage; lat = 49.1424721420109, lon = 9.149063227242355)
ac_bus_idx = _EUGO.find_closest_bus(zone_grid_un, 49.1424721420109, 9.149063227242355)
_EUGO.add_converter!(zone_grid_un, ac_bus_idx, dc_bus_idx_gg, power_rating)
_EUGO.add_dc_branch!(zone_grid_un, dc_bus_idx_bb, dc_bus_idx_gg, power_rating)


### Carry out OPF
# Start runnning hourly OPF calculations
hour_start_idx = 1 
hour_end_idx =  720
s = Dict("output" => Dict("branch_flows" => true), "conv_losses_mp" => true, "fix_cross_border_flows" => true)
batch_size = 360
batch_opf(hour_start_idx, hour_end_idx, zone_grid, timeseries_data, gurobi, s, batch_size, output_file_name)
batch_opf(hour_start_idx, hour_end_idx, zone_grid_un, timeseries_data, gurobi, s, batch_size, output_file_name_un)


## Load and process results
result, tc = _EUGO.process_results(hour_start_idx, hour_end_idx, batch_size, output_file_name)
result_un, tc_un = _EUGO.process_results(hour_start_idx, hour_end_idx, batch_size, output_file_name_un)
print("Total cost = ", tc / 1e6, " MEuro", "\n")
print("Total cost UN = ", tc_un / 1e6, " MEuro")

###############

# fn = join([output_file_name, "_opf_","1","_to_","730",".json"])
# res = Dict()
# open(fn) do f
#     dicttxt = read(f,String)  # file information to string
#     global res = JSON.parse(dicttxt)  # parse and transform data
# end
# cost = sum([hour["objective"] for (h, hour) in res])

# fn = join([output_file_name_un, "_opf_","1","_to_","730",".json"])
# res_un = Dict()
# open(fn) do f
#     dicttxt = read(f,String)  # file information to string
#     global res_un = JSON.parse(dicttxt)  # parse and transform data
# end
# cost_un = sum([hour["objective"] for (h, hour) in res_un])



# Plots.plot([abs(branch["pf"]) / zone_grid["branch"][b]["rate_a"]  for (b, branch) in res["1"]["solution"]["branch"]])
# Plots.plot([sum([gen["pg"] for (g, gen) in hour["solution"]["gen"]]) for (h, hour) in res])

# curt = zeros(1, length(res))
# curt_un = zeros(1, length(res))
# for (h, hour) in res
#     curt[1, parse(Int, h)] =  sum([load["pcurt"] for (l, load) in res[h]["solution"]["load"]])
#     curt_un[1, parse(Int, h)] = sum([load["pcurt"] for (l, load) in res_un[h]["solution"]["load"]]) 
# end
# Plots.plot(curt[1,:])
# Plots.plot!(curt_un[1,:])

# Plots.plot([hour["solution"]["branchdc"]["100"]["pf"] for (h, hour) in res_un])
# Plots.plot!([hour["solution"]["branchdc"]["99"]["pf"] for (h, hour) in res_un])

# for (l, load) in res["23"]["solution"]["load"]
#     if load["pcurt"] !=0.0
#         print(l, " -> ",load["pcurt"] , "\n")
#     end
# end

# for (l, load) in res["138"]["solution"]["load"]
#     if load["pcurt"] !=0.0
#         print(l, " -> ",load["pcurt"] , "\n")
#     end
# end

# for (b, branch) in zone_grid["branch"]
#     if branch["f_bus"] == 1229 || branch["t_bus"] == 1229
#         print(b, " - > ", branch["rate_a"], "\n")
#     end
# end


# zone_grid_hourly = deepcopy(zone_grid)
# _EUGO.hourly_grid_data!(zone_grid_hourly, zone_grid, 138, timeseries_data)
# _EUGO.hourly_grid_data!(zone_grid_hourly, zone_grid, 23, timeseries_data)

# g_cap = 0
# for (g, gen) in zone_grid_hourly["gen"]
#     if gen["type"] !== "XB_dummy"
#         g_cap = g_cap + gen["pmax"]
#     end
# end
# print(g_cap, " ", sum([load["pd"] for (l, load) in zone_grid_hourly["load"]]))



# Plots.plot([gen["pmax"]*100 for (g, gen) in zone_grid["gen"]]) 

# gen_max = 0
# for (g, gen) in zone_grid_h["gen"]
#     if gen["type_tyndp"] == "Onshore Wind"
#         gen_max = gen_max + gen["pmax"]
#     end
# end
# print(gen_max, "\n")


# Plots.plot([hour["solution"]["branchdc"]["98"]["pf"] for (h, hour) in res_un])
# marker = attr(size=[20, 30, 15, 10],
# color=[10, 20, 40, 50],
# cmin=0,
# cmax=50,
# colorscale="Greens",
# colorbar=attr(title="Some rate",
#               ticksuffix="%",
#               showticksuffix="last"),
# line_color="black")

# lat = [bus["lat"] for (b, bus) in zone_grid["bus"]]
# lon = [bus["lon"] for (b, bus) in zone_grid["bus"]]

# trace = PlotlyJS.scatter(;x=x, y=y, mode="markers")

# trace_nodes = PlotlyJS.scattergeo(;locationmode="europe", lat=lat, lon=lon, mode="markers")

# #trace = scattergeo(;mode="markers", locations=["FRA", "DEU", "RUS", "ESP"],marker=marker, name="Europe Data")
# layout = Layout(geo_scope="europe", geo_resolution=50, width=500, height=550,margin=attr(l=0, r=0, t=10, b=0))
# PlotlyJS.plot(trace, layout)
# trace_branches = []
# for (b, branch) in zone_grid["branch"]
#     f_bus = branch["f_bus"]
#     t_bus = branch["t_bus"]
#     if haskey(zone_grid["bus"], "$f_bus") && haskey(zone_grid["bus"], "$t_bus") 
#         lat = [zone_grid["bus"]["$f_bus"]["lat"], zone_grid["bus"]["$t_bus"]["lat"]]
#         lon = [zone_grid["bus"]["$f_bus"]["lon"], zone_grid["bus"]["$t_bus"]["lon"]]
#         push!(trace_branches, PlotlyJS.scatter(;lat=lat, lon=lon, mode="lines"))
#     end
# end

# PlotlyJS.plot(trace_branches, layout)



# # for (r, res) in result
# #     if isempty(res["solution"])
# #         print(r, " -> ", res["termination_status"],  "\n")
# #     end
# # end
# # for a = 1:12
# #     zone_grid_hourly["borders"]["$a"]["slack"] = 0
# # end
# # zone_grid_hourly["borders"]["5"]["slack"] = 0.06
# # # zone_grid_hourly["borders"]["6"]["slack"] = 0.06
# # # zone_grid_hourly["borders"]["7"]["slack"] = 0.06
# # zone_grid_hourly["borders"]["8"]["slack"] = 0.01
# # zone_grid_hourly["borders"]["13"]["slack"] = 0.01
# # res = CBAOPF.solve_cbaopf(zone_grid_hourly, DCPPowerModel, Gurobi.Optimizer; setting = s) 

# # ###### Validation ###########

# # hour = "1"
# # res_h = result[hour]["solution"]

# # for (bo, border) in zone_grid_hourly["borders"]
# #     xb_flow_in = border["flow"]
# #     xb_flow_out = 0
# #     border_cap = 0
# #     for (b, branch) in border["xb_lines"]
# #         if branch["direction"] == "from"
# #             xb_flow_out =  xb_flow_out + res_h["branch"][b]["pf"]
# #         else
# #             xb_flow_out =  xb_flow_out + res_h["branch"][b]["pt"]
# #         end
# #         border_cap = border_cap + branch["rate_a"]
# #     end
# #     for (c, conv) in border["xb_convs"]
# #         xb_flow_out = xb_flow_out - res_h["convdc"][c]["pgrid"]
# #         border_cap = border_cap + conv["Pacmax"]
# #     end
# #     print(border["name"], " ", xb_flow_in, " ", xb_flow_out, " cap: ",border_cap,  "\n") 
# # end


# # for (c, conv) in zone_grid_hourly["convdc"]
# #     if conv["busdc_i"] == 10193
# #         print(c, "\n")
# #     end
# # end

# # for (b, branch) in zone_grid_hourly["branchdc"]
# #     if branch["fbusdc"] == 10204 || branch["tbusdc"] == 10204
# #         print("10204 -> ", b, "\n" )
# #     end
# #     if branch["fbusdc"] == 10205 || branch["tbusdc"] == 10205
# #         print("10204 -> ", b, "\n" )
# #     end
# # end


# # for (b, branch) in zone_grid_hourly["branch"]
# #     if branch["f_bus"] == 5941 || branch["t_bus"] == 5941
# #         print(b, "\n")
# #     end
# # end