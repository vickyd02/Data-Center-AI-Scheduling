# Digital Twin Co-Optimization of District Energy Networks and Flexible AI Workloads

**Authors:** Victoria Dinov, Jasmine Blust, Morgan Wyatt  
**Course:** ENERGY 291 · Stanford University  

## Overview

The explosive growth of generative AI has introduced unprecedented challenges for grid operators. Historically treated as static, inflexible loads, modern data centers possess an unexploited opportunity to act as dynamic demand-side agents. 

This project explores the asynchronous nature of deep learning training, which provides inherent flexibility to shift delay-tolerant workloads to optimized periods. By treating AI compute capacity as a Virtual Power Plant (VPP), data center operators can dynamically modulate real-time power consumption in response to grid stress, price volatility, and marginal carbon signals. 

We developed a digital twin simulation coupling the computational dispatch of a 6 MW AI supercomputing cluster with the thermal energy storage (TES) operations of Stanford's Central Energy Facility (CEF). The model utilizes a multi-period Mixed-Integer Linear Programming (MILP) optimization framework executed within a 48-hour rolling-horizon Model Predictive Control (MPC) window to co-optimize physical utility networks and virtual compute queues.

---

## Key Results

The rolling MPC framework was benchmarked across an 8,760-hour annual horizon against an uncoordinated baseline (a zero-queue-delay scenario forcing all excess compute capacity to AWS Spot instances at $1,200/MWh). 

By introducing a 500 MWh virtual queue (maximum 5-day delay tolerance), the framework acts as a "computational shock absorber," completely eliminating the need for expensive public cloud outsourcing.

| Metric | Uncoordinated Baseline | Optimized MPC Model | Total Savings / Reduction |
| :--- | :--- | :--- | :--- |
| **Total Operational Cost** | $15,177,824 | $7,964,237 | **$7,964,237 (52.5%)** |
| **Total Carbon Emissions** | 27,286 MT CO₂ | 24,360 MT CO₂ | **2,926 MT CO₂ (10.7%)** |
| **Cloud Outsourcing Cost** | >$7.2 Million | $0 | **100% Eliminated** |

### Operational Highlights
* **Peak Shaving & Diurnal Shifting:** The model does not perform classical peak shaving; instead, it executes a rightward compression of the Load Duration Curve. It actively suppresses grid draw during the expensive, carbon-intensive duck curve "neck" (hours 16–21).
* **Decarbonization:** The solver successfully shifts processing into the night and solar-dominant midday periods, arbitraging both cost and grid-level emissions without requiring new capital-intensive infrastructure.
* **Multi-Objective Trade-offs:** Sensitivity analysis revealed a "Trade-off Zone" where the algorithm deliberately accepts a marginal increase in off-peak financial costs to secure steeper, continuous drops in grid carbon emissions.

---

## Data Sources

The simulation integrates three distinct empirical datasets aligned across an 8,760-hour annual horizon (May 2025–May 2026):

| Dataset | Variables Tracked | Source |
| :--- | :--- | :--- |
| **Stanford CEF Operational Data** | Cooling/Heating demand, TES states of charge, HRC cooling limits, chiller parameters, day-ahead CAISO electricity prices. | Stanford Central Energy Facility |
| **Cambium Emission Forecasts** | Levelized Long-Run Marginal Emission Rate (LRMER) for California. | NREL (2024) |
| **Alibaba GPU Cluster Trace** | CPU/GPU utilization, job start/end times (scaled to a 36,500 MWh annual payload for Stanford's 6 MW envelope). | Alibaba Cluster Trace Program (2020) |

---

## Methods: Mathematical Formulation

The core of the digital twin is a deterministic MILP model utilizing continuous decision variables for energy flows and a binary variable for Heat Recovery Chiller (HRC) commitment. 

The objective function minimizes a weighted scalarized sum of operational costs ($C_{total}$), lifecycle carbon emissions ($E_{total}$), and AI workload queuing delays ($Q_{total}$), bounded by fixed normalization denominators ($\eta$) to prevent magnitude dominance:

$$\min w_{cost}\left(\frac{C_{total}}{\eta_{cost}}\right) + w_{carbon}\left(\frac{E_{total}}{\eta_{carbon}}\right) + w_{speed}\left(\frac{Q_{total}}{\eta_{speed}}\right)$$

The model strictly adheres to thermodynamic balances for chilled water ($S^{chw}$) and hot water ($S^{hw}$) thermal energy storage tanks. AI compute heat rejection is coupled to the chilled water tank using a standard Power Usage Effectiveness (PUE) multiplier of 1.15.

---

## Repository Structure & Code Architecture

The underlying simulation is built in **Julia**, utilizing the `JuMP` mathematical optimization modeling language and the open-source `HiGHS` solver.

### Code Pipeline
1. **Empirical Data Processing:** Reads and cleans raw Excel data for Stanford thermodynamic demands, CAISO pricing, and NREL Cambium emissions constraints.
2. **System Boundaries:** Initializes all thermodynamic constants (e.g., maximum queue delays, HRC conversion ratios, conventional chiller COPs).
3. **Raw AI Demand Synthesis:** Parses the massive Alibaba cluster trace (`job_table`, `task_table`, `sensor_table`) to generate a dynamic 8,760-hour compute trace, scaling power parameters accurately to megawatt loads.
4. **48-Hour Rolling MILP Engine:** Defines the decision variables, objective function, and constraints. Implements a `baseline_mode` toggle to easily switch between zero-delay uncoordinated behavior and intelligent MPC queueing.
5. **Orchestration Loop:** Marches through the 365-day simulation, committing only the first 24 hours of the 48-hour prediction window to the state vector before rolling forward.

---

## Installation & Usage

### Prerequisites
* **Julia** (v1.8+ recommended)
* Required Julia Packages:
  * `JuMP`
  * `HiGHS`
  * `CSV`
  * `DataFrames`
  * `XLSX`

### Setup
1. Clone this repository to your local machine.
2. Update the absolute file paths at the top of the Julia script to point to your local dataset locations:
   ```julia
   stanford_file = "/path/to/Stanford CEF Data Request for Dinov and Blust.xlsx"
   nrel_file     = "/path/to/Cambium24_Workbook.xlsx"
   job_csv       = "/path/to/pai_job_table.csv"
   task_csv      = "/path/to/pai_task_table.csv"
   sensor_csv    = "/path/to/pai_sensor_table.csv"
