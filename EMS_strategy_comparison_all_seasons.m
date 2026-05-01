clc;
clear;
close all;
tic;

%% =========================================================
%  Three-strategy comparison across all seasons
%
%  Strategies:
%  1) Day-ahead MILP optimisation
%  2) Receding-horizon MPC
%  3) Rule-based baseline
%
%  For each season:
%    - Generate 20 synthetic daily scenarios by slot-wise resampling
%    - Use the same input profiles for all three strategies
%
%  Final output:
%    - Seasonal summary tables and seasonal plots
%    - Combined overall summary table across all seasons
%    - Combined cost, saving, BESS scheduling and grid import/export plots
%    - One 4x2 figure for seasonal mean charge/discharge comparison
%    - One seasonal PV/Wind generation summary table
%
%  Applied modifications:
%    1) targetLCLid = MAC000022
%    2) load year = 2012
%    3) load scaling: original_annual_load = 4235, target_annual_load = 6700
%    4) load data read as Load_kWh and Pload_kW
%    5) wind :1kW
%    6) PV is multiplied by 0.25 because the original PV profile represents
%       a 4 kW PV system. Multiplying by 1/4 converts it to a 1 kW PV profile.
%  Note:
%    - No BESS time-window constraints are applied in this version.
%% =========================================================

%% ---------------------------
%  User settings
%% ---------------------------
targetLCLid = 'MAC000022';  % Selected household ID from the Low Carbon London dataset
target_year_load = 2012;    % Year of household demand data used for the simulation

Nrun_per_season = 20;
T = 48;
dt = 0.5;

N_H = 6;                % MPC horizon, 6 slots = 3 hours

season_names = {'spring', 'summer', 'autumn', 'winter'};

season_months = struct( ...
    'spring', [3 4 5], ...
    'summer', [6 7 8], ...
    'autumn', [9 10 11], ...
    'winter', [12 1 2]);

%% ---------------------------
%  System parameters
%% ---------------------------
Ubat = 13.5;                % kWh

SOC_init_pu = 0.3;    % Initial battery state of charge in per unit
SOC_min_pu  = 0.1;    % Minimum allowable battery state of charge in per unit
SOC_max_pu  = 0.9;    % Maximum allowable battery state of charge in per unit

% Convert per-unit SoC limits into battery energy values in kWh
Soc_init_kWh = SOC_init_pu * Ubat;   % Initial battery energy in kWh
Soc_min_kWh  = SOC_min_pu  * Ubat;   % Minimum allowable battery energy in kWh
Soc_max_kWh  = SOC_max_pu  * Ubat;   % Maximum allowable battery energy in kWh

eta_cha = 0.943;   % Battery charging efficiency
eta_dis = 0.943;   % Battery discharging efficiency
eta     = 0.943;   % Single efficiency parameter used in the MPC model

e_bat = 0.0001;   % Self-discharge rate per half-hour time step, used as a small standby loss assumption

Pcha_max = 0.3 * Ubat;      % 4.05 kW
Pdis_max = 0.3 * Ubat;      % 4.05 kW
Pgrid_max = 13.8;           % kW

C_stand = 55.79;            % pence/day

% Rule-based peak periods
% 07:00–09:00: slots 15:18
% 12:00–14:00: slots 25:28
% 18:00–23:00: slots 37:46
peak_slots = [15:18, 25:28, 37:46];
peak_windows = {15:18, 25:28, 37:46};

SOC_peak_target = SOC_init_pu;

%% ---------------------------
%  Load scaling
%% ---------------------------
original_annual_load = 4235;
target_annual_load   = 6700;
load_scale = target_annual_load / original_annual_load;

%% =========================================================
%  Read household load data
%% =========================================================
fprintf('Loading household demand data...\n');

try
    Pload_all = readtable('LCL-June2015v2_0.xlsx', ...
        'Sheet', 'LCL-June2015v2_0');
catch
    error('Failed to read household load Excel file.');
end

Pload_all = Pload_all(strcmp(Pload_all.LCLid, targetLCLid), :);

Pload_all.DateTime = datetime(Pload_all.DateTime, ...
    'InputFormat', 'yyyy/MM/dd H:mm:ss');

Pload_all = Pload_all(year(Pload_all.DateTime) == target_year_load, :);

if isempty(Pload_all)
    error('No load data found for %s in year %d.', targetLCLid, target_year_load);
end

% Original load data is kWh per half-hour.
% Apply load scaling first.
Pload_all.Load_kWh = Pload_all.KWH_hh_perHalfHour_ * load_scale;

% Convert scaled half-hourly energy to equivalent average power in kW.
% Pload_kW * dt = Load_kWh
Pload_all.Pload_kW = Pload_all.Load_kWh / dt;

Pload_all = addDayKeyAndSlot(Pload_all, 'DateTime');

fprintf('Load data loaded. Number of records = %d\n', height(Pload_all));
fprintf('Load scale factor = %.4f\n', load_scale);
fprintf('Scaled annual load = %.2f kWh\n\n', sum(Pload_all.Load_kWh, 'omitnan'));

%% =========================================================
%  Read wind data
%% =========================================================
fprintf('Loading wind data...\n');

try
    P_wt = readtable('ninja_wind_51.3228_-0.1038_corrected.xlsx', ...
        'Sheet', 'ninja_wind_51.3228_-0.1038_corr', ...
        'Range', 'A4:C10000', ...
        'VariableNamingRule','preserve');
catch
    error('Failed to read wind power Excel file.');
end

P_wt.time = datetime(P_wt.time, ...
    'InputFormat','yyyy/M/d H:mm');

% Convert hourly wind power to half-hourly data
n_wt = height(P_wt);
Time_wt_hh  = P_wt.time(1) + minutes(30) * (0:2*n_wt-1)';
Power_wt_hh = repelem(P_wt.electricity, 2);     % no multiplier

P_wt_hh = table(Time_wt_hh, Power_wt_hh, ...
    'VariableNames', {'Time','Power_kW'});

P_wt_hh = addDayKeyAndSlot(P_wt_hh, 'Time');

%% =========================================================
%  Read PV data
%% =========================================================
fprintf('Loading PV data...\n');

try
    P_pv = readtable('ninja_pv_51.3228_-0.1038_corrected.xlsx', ...
        'Sheet', 'ninja_pv_51.3228_-0.1038_correc', ...
        'Range', 'A4:C8788', ...
        'VariableNamingRule','preserve');
catch
    error('Failed to read PV Excel file.');
end

P_pv.time = datetime(P_pv.time, ...
    'InputFormat','yyyy/M/d H:mm');

% Convert hourly PV power to half-hourly data
n_pv = height(P_pv);
Time_pv_hh  = P_pv.time(1) + minutes(30) * (0:2*n_pv-1)';
Power_pv_hh = 0.25 * repelem(P_pv.electricity, 2);

P_pv_hh = table(Time_pv_hh, Power_pv_hh, ...
    'VariableNames', {'Time','Power_kW'});

P_pv_hh = addDayKeyAndSlot(P_pv_hh, 'Time');

%% =========================================================
%  Read tariff data
%% =========================================================
fprintf('Loading tariff data...\n');

try
    price_tbl = readtable( ...
        'agile-half-hour-actual-rates-01-01-2024_31-12-2024.xlsx', ...
        'Sheet', 'agile-half-hour-actual-rates-01', ...
        'VariableNamingRule', 'preserve');
catch
    error('Failed to read electricity tariff Excel file.');
end

price_tbl.("Period from") = datetime(price_tbl.("Period from"), ...
    'InputFormat', 'dd/MM/yyyy HH:mm');

price_tbl.("Period to") = datetime(price_tbl.("Period to"), ...
    'InputFormat', 'dd/MM/yyyy HH:mm');

price_tbl = addDayKeyAndSlot(price_tbl, 'Period from');

fprintf('Tariff data loaded. Number of records = %d\n', height(price_tbl));
fprintf('All data loaded.\n\n');

%% =========================================================
%  Overall result containers
%% =========================================================
N_total = Nrun_per_season * numel(season_names);

F_dayahead_all  = nan(1, N_total);
F_mpc_all       = nan(1, N_total);
F_rule_all      = nan(1, N_total);
F_nocontrol_all = nan(1, N_total);

Save_dayahead_all = nan(1, N_total);
Save_mpc_all      = nan(1, N_total);
Save_rule_all     = nan(1, N_total);

Season_label = strings(N_total, 1);

Pload_all_runs = nan(T, N_total);
Load_kWh_all_runs = nan(T, N_total);
Price_buy_all_runs = nan(T, N_total);
Price_sell_all_runs = nan(T, N_total);

Pwt_all_runs = nan(T, N_total);
Ppv_all_runs = nan(T, N_total);

Pcha_dayahead_all  = nan(T, N_total);
Pdis_dayahead_all  = nan(T, N_total);
Pbuy_dayahead_all  = nan(T, N_total);
Psell_dayahead_all = nan(T, N_total);
SOC_dayahead_all   = nan(T+1, N_total);

Pcha_mpc_all  = nan(T, N_total);
Pdis_mpc_all  = nan(T, N_total);
Pbuy_mpc_all  = nan(T, N_total);
Psell_mpc_all = nan(T, N_total);
SOC_mpc_all   = nan(T+1, N_total);

Pcha_rule_all  = nan(T, N_total);
Pdis_rule_all  = nan(T, N_total);
Pbuy_rule_all  = nan(T, N_total);
Psell_rule_all = nan(T, N_total);
SOC_rule_all   = nan(T+1, N_total);

PV_gen_all   = nan(1, N_total);   % kWh/day
Wind_gen_all = nan(1, N_total);   % kWh/day

%% =========================================================
%  Main loop across seasons
%% =========================================================


global_run_idx = 0;

for s = 1:numel(season_names)

    SEASON = season_names{s};
    months_sel = season_months.(SEASON);

    fprintf('==============================\n');
    fprintf('Processing season: %s\n', SEASON);
    fprintf('==============================\n');

    %% Select seasonal data
    Pload_season = Pload_all(ismember(month(Pload_all.DateTime), months_sel), :);
    P_wt_season  = P_wt_hh(ismember(month(P_wt_hh.Time), months_sel), :);
    P_pv_season  = P_pv_hh(ismember(month(P_pv_hh.Time), months_sel), :);
    price_season = price_tbl(ismember(month(price_tbl.("Period from")), months_sel), :);

    %% Find common complete seasonal day keys
    keys_load  = getCompleteDayKeys(Pload_season.DayKey);
    keys_wt    = getCompleteDayKeys(P_wt_season.DayKey);
    keys_pv    = getCompleteDayKeys(P_pv_season.DayKey);
    keys_price = getCompleteDayKeys(price_season.DayKey);

    fprintf('Complete load %s keys  = %d\n', SEASON, numel(keys_load));
    fprintf('Complete wind %s keys  = %d\n', SEASON, numel(keys_wt));
    fprintf('Complete PV %s keys    = %d\n', SEASON, numel(keys_pv));
    fprintf('Complete price %s keys = %d\n', SEASON, numel(keys_price));

    season_keys = intersect(intersect(intersect(keys_load, keys_wt), keys_pv), keys_price);

    if isempty(season_keys)
        error('No common complete %s day keys found.', SEASON);
    end

    fprintf('Number of complete common %s day keys = %d\n\n', SEASON, numel(season_keys));

    %% =====================================================
    %  Monte Carlo runs within this season
    %% =====================================================
    for run_idx = 1:Nrun_per_season

        global_run_idx = global_run_idx + 1;
        Season_label(global_run_idx) = string(SEASON);

        fprintf('%s run %d / %d, overall run %d / %d\n', ...
            SEASON, run_idx, Nrun_per_season, global_run_idx, N_total);

        %% -------------------------------------------------
        %  Generate one identical synthetic day input
        %% -------------------------------------------------
        selected_keys = season_keys(randi(numel(season_keys), T, 1));

        price_buy  = nan(T,1);
        price_sell = nan(T,1);
        Pload_day  = nan(T,1);
        Load_kWh_day = nan(T,1);
        Pwt_day    = nan(T,1);
        Ppv_day    = nan(T,1);

        for slot = 1:T

            key = selected_keys(slot);

            row_price = price_season( ...
                price_season.DayKey == key & price_season.Slot == slot, :);

            row_load = Pload_season( ...
                Pload_season.DayKey == key & Pload_season.Slot == slot, :);

            row_wt = P_wt_season( ...
                P_wt_season.DayKey == key & P_wt_season.Slot == slot, :);

            row_pv = P_pv_season( ...
                P_pv_season.DayKey == key & P_pv_season.Slot == slot, :);

            if height(row_price) ~= 1 || height(row_load) ~= 1 || ...
               height(row_wt) ~= 1 || height(row_pv) ~= 1
                error('Synthetic day construction failed at season %s, run %d, slot %d.', ...
                    SEASON, run_idx, slot);
            end

            price_buy(slot)  = row_price.("Agile Import price (p/kWh)");
            price_sell(slot) = row_price.("Agile Export price (p/kWh)");

            Load_kWh_day(slot) = row_load.Load_kWh;
            Pload_day(slot)    = row_load.Pload_kW;

            Pwt_day(slot) = row_wt.Power_kW;
            Ppv_day(slot) = row_pv.Power_kW;

        end

        %% Store input profiles
        Pload_all_runs(:, global_run_idx) = Pload_day;
        Load_kWh_all_runs(:, global_run_idx) = Load_kWh_day;
        Price_buy_all_runs(:, global_run_idx) = price_buy;
        Price_sell_all_runs(:, global_run_idx) = price_sell;
        Pwt_all_runs(:, global_run_idx) = Pwt_day;
        Ppv_all_runs(:, global_run_idx) = Ppv_day;

        %% Store daily renewable generation
        PV_gen_all(global_run_idx)   = sum(Ppv_day) * dt;
        Wind_gen_all(global_run_idx) = sum(Pwt_day) * dt;

        %% -------------------------------------------------
        %  Common no-control cost
        %% -------------------------------------------------
        F_nocontrol = sum(price_buy .* Pload_day * dt) + C_stand;
        F_nocontrol_all(global_run_idx) = F_nocontrol;

        %% -------------------------------------------------
        %  Strategy 1: Day-ahead MILP
        %% -------------------------------------------------
        [res_da, ok_da] = run_dayahead_milp( ...
            Pload_day, Pwt_day, Ppv_day, price_buy, price_sell, ...
            T, dt, Ubat, SOC_init_pu, SOC_min_pu, SOC_max_pu, ...
            eta_cha, eta_dis, e_bat, Pcha_max, Pdis_max, Pgrid_max, C_stand);

        if ok_da
            F_dayahead_all(global_run_idx) = res_da.cost;
            Save_dayahead_all(global_run_idx) = F_nocontrol - res_da.cost;

            Pcha_dayahead_all(:, global_run_idx)  = res_da.Pcha;
            Pdis_dayahead_all(:, global_run_idx)  = res_da.Pdis;
            Pbuy_dayahead_all(:, global_run_idx)  = res_da.Pbuy;
            Psell_dayahead_all(:, global_run_idx) = res_da.Psell;
            SOC_dayahead_all(:, global_run_idx)   = res_da.SOC_pu;
        else
            warning('Day-ahead MILP failed at season %s, run %d.', SEASON, run_idx);
        end

        %% -------------------------------------------------
        %  Strategy 2: Receding-horizon MPC
        %% -------------------------------------------------
        [res_mpc, ok_mpc] = run_mpc_strategy( ...
            Pload_day, Pwt_day, Ppv_day, price_buy, price_sell, ...
            T, N_H, dt, Ubat, Soc_init_kWh, Soc_min_kWh, Soc_max_kWh, ...
            eta, e_bat, Pcha_max, Pdis_max, Pgrid_max, C_stand);

        if ok_mpc
            F_mpc_all(global_run_idx) = res_mpc.cost;
            Save_mpc_all(global_run_idx) = F_nocontrol - res_mpc.cost;

            Pcha_mpc_all(:, global_run_idx)  = res_mpc.Pcha;
            Pdis_mpc_all(:, global_run_idx)  = res_mpc.Pdis;
            Pbuy_mpc_all(:, global_run_idx)  = res_mpc.Pbuy;
            Psell_mpc_all(:, global_run_idx) = res_mpc.Psell;
            SOC_mpc_all(:, global_run_idx)   = res_mpc.SOC_kWh / Ubat;
        else
            warning('MPC failed at season %s, run %d.', SEASON, run_idx);
        end

        %% -------------------------------------------------
        %  Strategy 3: Rule-based baseline
        %% -------------------------------------------------
        res_rule = run_rule_based_baseline( ...
            Pload_day, Pwt_day, Ppv_day, price_buy, price_sell, ...
            T, dt, Ubat, SOC_init_pu, SOC_min_pu, SOC_max_pu, SOC_peak_target, ...
            eta_cha, eta_dis, e_bat, Pcha_max, Pdis_max, Pgrid_max, C_stand, ...
            peak_slots, peak_windows);

        F_rule_all(global_run_idx) = res_rule.cost;
        Save_rule_all(global_run_idx) = F_nocontrol - res_rule.cost;

        Pcha_rule_all(:, global_run_idx)  = res_rule.Pcha;
        Pdis_rule_all(:, global_run_idx)  = res_rule.Pdis;
        Pbuy_rule_all(:, global_run_idx)  = res_rule.Pbuy;
        Psell_rule_all(:, global_run_idx) = res_rule.Psell;
        SOC_rule_all(:, global_run_idx)   = res_rule.SOC_pu;

    end
end

%% =========================================================
%  Valid runs across all seasons
%% =========================================================
valid_da   = ~isnan(F_dayahead_all);
valid_mpc  = ~isnan(F_mpc_all);
valid_rule = ~isnan(F_rule_all);

valid_all = valid_da & valid_mpc & valid_rule;

if ~any(valid_all)
    error('No valid runs were completed for all three strategies.');
end

fprintf('\nTotal valid comparison runs = %d / %d\n', sum(valid_all), N_total);

%% =========================================================
%  Time labels for x-axis
%% =========================================================
tick_step = 4;

time_vec_48 = datetime(2000,1,1,0,0,0) + minutes(30)*(0:T-1);
time_lbl_48 = cellstr(string(time_vec_48, 'HH:mm'));

time_vec_49 = datetime(2000,1,1,0,0,0) + minutes(30)*(0:T);
time_lbl_49 = cellstr(string(time_vec_49, 'HH:mm'));
time_lbl_49{end} = '24:00';

%% =========================================================
%  Seasonal cost summary tables and seasonal plots
%% =========================================================
for s = 1:numel(season_names)

    SEASON_now = season_names{s};

    season_idx = valid_all & (Season_label' == string(SEASON_now));

    if ~any(season_idx)
        warning('No valid runs found for %s.', SEASON_now);
        continue;
    end

    fprintf('\n=====================================\n');
    fprintf('Seasonal summary: %s\n', SEASON_now);
    fprintf('=====================================\n');

    %% Extract seasonal cost results
    cost_no_control_season = F_nocontrol_all(season_idx);
    cost_dayahead_season   = F_dayahead_all(season_idx);
    cost_mpc_season        = F_mpc_all(season_idx);
    cost_rule_season       = F_rule_all(season_idx);

    saving_no_control_season = zeros(size(cost_no_control_season));
    saving_dayahead_season   = cost_no_control_season - cost_dayahead_season;
    saving_mpc_season        = cost_no_control_season - cost_mpc_season;
    saving_rule_season       = cost_no_control_season - cost_rule_season;

    mean_no_control_season = mean(cost_no_control_season, 'omitnan');

    %% Seasonal summary table
    Strategy = {
        'No control';
        'Day-ahead MILP';
        'MPC';
        'Rule-based'
    };

    Mean_Cost_pence = [
        mean(cost_no_control_season, 'omitnan');
        mean(cost_dayahead_season,   'omitnan');
        mean(cost_mpc_season,        'omitnan');
        mean(cost_rule_season,       'omitnan')
    ];

    Std_Cost_pence = [
        std(cost_no_control_season, 0, 'omitnan');
        std(cost_dayahead_season,   0, 'omitnan');
        std(cost_mpc_season,        0, 'omitnan');
        std(cost_rule_season,       0, 'omitnan')
    ];

    Mean_Saving_pence = [
        mean(saving_no_control_season, 'omitnan');
        mean(saving_dayahead_season,   'omitnan');
        mean(saving_mpc_season,        'omitnan');
        mean(saving_rule_season,       'omitnan')
    ];

    Saving_percent = Mean_Saving_pence ./ mean_no_control_season * 100;

    Mean_Saving_display = string(round(Mean_Saving_pence, 2));
    Saving_percent_display = string(round(Saving_percent, 3));

    Mean_Saving_display(1) = "N/A";
    Saving_percent_display(1) = "N/A";

    Daily_Load_kWh_season = sum(Load_kWh_all_runs(:, season_idx), 1, 'omitnan');

    Mean_Daily_Load_kWh = [
        mean(Daily_Load_kWh_season, 'omitnan');
        mean(Daily_Load_kWh_season, 'omitnan');
        mean(Daily_Load_kWh_season, 'omitnan');
        mean(Daily_Load_kWh_season, 'omitnan')
    ];

    Seasonal_summary = table( ...
        Strategy, ...
        round(Mean_Cost_pence, 3), ...
        round(Std_Cost_pence, 3), ...
        Mean_Saving_display, ...
        Saving_percent_display, ...
        round(Mean_Daily_Load_kWh, 3), ...
        'VariableNames', {'Strategy', 'Mean_Cost_pence', 'Std_Cost_pence', ...
                          'Mean_Saving_pence', 'Saving_percent', ...
                          'Mean_Daily_Load_kWh'});

    disp(Seasonal_summary);

    output_filename = ['cost_reduction_summary_', char(SEASON_now), '.xlsx'];
    writetable(Seasonal_summary, output_filename);

    fprintf('Seasonal summary table saved to: %s\n', output_filename);

    %% Seasonal cost comparison plot
    cost_matrix_season = [ ...
        cost_no_control_season', ...
        cost_dayahead_season', ...
        cost_mpc_season', ...
        cost_rule_season' ];

    figure;
    bar(cost_matrix_season);
    xlabel('Randomly sampled daily scenario index');
    ylabel('Daily cost (pence)');
    title(['Daily cost comparison under ', char(SEASON_now), ' scenario random sampling']);
    legend('No control', 'Day-ahead MILP', 'MPC', 'Rule-based', 'Location', 'best');
    grid on;

    %% Seasonal mean cost plot
    figure;
    bar(Mean_Cost_pence);
    set(gca, 'XTickLabel', {'No control','Day-ahead','MPC','Rule-based'});
    ylabel('Mean daily cost (pence)');
    title(['Mean daily cost comparison - ', char(SEASON_now)]);
    grid on;

    %% Seasonal saving comparison plot
    saving_matrix_season = [ ...
        saving_dayahead_season', ...
        saving_mpc_season', ...
        saving_rule_season' ];

    figure;
    bar(saving_matrix_season);
    xlabel('Randomly sampled daily scenario index');
    ylabel('Saving compared with no control (pence)');
    title(['Cost saving comparison under ', char(SEASON_now), ' scenario random sampling']);
    legend('Day-ahead MILP', 'MPC', 'Rule-based', 'Location', 'best');
    grid on;

    %% Seasonal saving percentage plot
    figure;
    bar(Saving_percent);
    set(gca, 'XTickLabel', {'No control','Day-ahead','MPC','Rule-based'});
    ylabel('Saving (%)');
    title(['Saving percentage compared with no control - ', char(SEASON_now)]);
    grid on;

    %% Seasonal mean charging power
    Pcha_da_mean_season   = mean(Pcha_dayahead_all(:, season_idx), 2, 'omitnan');
    Pcha_mpc_mean_season  = mean(Pcha_mpc_all(:, season_idx), 2, 'omitnan');
    Pcha_rule_mean_season = mean(Pcha_rule_all(:, season_idx), 2, 'omitnan');

    figure;
    plot(1:T, Pcha_da_mean_season, '-o', 'LineWidth', 1.2); hold on;
    plot(1:T, Pcha_mpc_mean_season, '-s', 'LineWidth', 1.2);
    plot(1:T, Pcha_rule_mean_season, '-^', 'LineWidth', 1.2);
    xlabel('Time of day');
    ylabel('Mean charging power (kW)');
    title(['Mean charging power comparison - ', char(SEASON_now)]);
    legend('Day-ahead MILP', 'MPC', 'Rule-based', 'Location', 'best');
    xticks(1:tick_step:T);
    xticklabels(time_lbl_48(1:tick_step:T));
    xtickangle(45);
    grid on;

    %% Seasonal mean discharging power
    Pdis_da_mean_season   = mean(Pdis_dayahead_all(:, season_idx), 2, 'omitnan');
    Pdis_mpc_mean_season  = mean(Pdis_mpc_all(:, season_idx), 2, 'omitnan');
    Pdis_rule_mean_season = mean(Pdis_rule_all(:, season_idx), 2, 'omitnan');

    figure;
    plot(1:T, Pdis_da_mean_season, '-o', 'LineWidth', 1.2); hold on;
    plot(1:T, Pdis_mpc_mean_season, '-s', 'LineWidth', 1.2);
    plot(1:T, Pdis_rule_mean_season, '-^', 'LineWidth', 1.2);
    xlabel('Time of day');
    ylabel('Mean discharging power (kW)');
    title(['Mean discharging power comparison - ', char(SEASON_now)]);
    legend('Day-ahead MILP', 'MPC', 'Rule-based', 'Location', 'best');
    xticks(1:tick_step:T);
    xticklabels(time_lbl_48(1:tick_step:T));
    xtickangle(45);
    grid on;

    %% Seasonal mean grid import power
    Pbuy_da_mean_season   = mean(Pbuy_dayahead_all(:, season_idx), 2, 'omitnan');
    Pbuy_mpc_mean_season  = mean(Pbuy_mpc_all(:, season_idx), 2, 'omitnan');
    Pbuy_rule_mean_season = mean(Pbuy_rule_all(:, season_idx), 2, 'omitnan');

    figure;
    plot(1:T, Pbuy_da_mean_season, '-o', 'LineWidth', 1.2); hold on;
    plot(1:T, Pbuy_mpc_mean_season, '-s', 'LineWidth', 1.2);
    plot(1:T, Pbuy_rule_mean_season, '-^', 'LineWidth', 1.2);
    xlabel('Time of day');
    ylabel('Mean grid import power (kW)');
    title(['Mean grid import comparison - ', char(SEASON_now)]);
    legend('Day-ahead MILP', 'MPC', 'Rule-based', 'Location', 'best');
    xticks(1:tick_step:T);
    xticklabels(time_lbl_48(1:tick_step:T));
    xtickangle(45);
    grid on;

    %% Seasonal mean grid export power
    Psell_da_mean_season   = mean(Psell_dayahead_all(:, season_idx), 2, 'omitnan');
    Psell_mpc_mean_season  = mean(Psell_mpc_all(:, season_idx), 2, 'omitnan');
    Psell_rule_mean_season = mean(Psell_rule_all(:, season_idx), 2, 'omitnan');

    figure;
    plot(1:T, Psell_da_mean_season, '-o', 'LineWidth', 1.2); hold on;
    plot(1:T, Psell_mpc_mean_season, '-s', 'LineWidth', 1.2);
    plot(1:T, Psell_rule_mean_season, '-^', 'LineWidth', 1.2);
    xlabel('Time of day');
    ylabel('Mean grid export power (kW)');
    title(['Mean grid export comparison - ', char(SEASON_now)]);
    legend('Day-ahead MILP', 'MPC', 'Rule-based', 'Location', 'best');
    xticks(1:tick_step:T);
    xticklabels(time_lbl_48(1:tick_step:T));
    xtickangle(45);
    grid on;

    %% Seasonal mean SoC trajectory
    SOC_da_mean_season   = mean(SOC_dayahead_all(:, season_idx), 2, 'omitnan');
    SOC_mpc_mean_season  = mean(SOC_mpc_all(:, season_idx), 2, 'omitnan');
    SOC_rule_mean_season = mean(SOC_rule_all(:, season_idx), 2, 'omitnan');

    figure;
    plot(0:T, SOC_da_mean_season, '-o', 'LineWidth', 1.2); hold on;
    plot(0:T, SOC_mpc_mean_season, '-s', 'LineWidth', 1.2);
    plot(0:T, SOC_rule_mean_season, '-^', 'LineWidth', 1.2);
    xlabel('Time of day');
    ylabel('Mean SoC (p.u.)');
    title(['Mean SoC trajectory comparison - ', char(SEASON_now)]);
    legend('Day-ahead MILP', 'MPC', 'Rule-based', 'Location', 'best');
    xticks(0:tick_step:T);
    xticklabels(time_lbl_49(1:tick_step:end));
    xtickangle(45);
    grid on;

end

%% =========================================================
%  Seasonal PV and Wind generation summary table
%% =========================================================
Season = strings(numel(season_names), 1);
PV_generation_kWh = nan(numel(season_names), 1);
Wind_generation_kWh = nan(numel(season_names), 1);

for s = 1:numel(season_names)
    SEASON_now = season_names{s};
    season_idx = valid_all & (Season_label' == string(SEASON_now));

    Season(s) = string(upper(SEASON_now(1))) + extractAfter(string(SEASON_now), 1);
    PV_generation_kWh(s) = mean(PV_gen_all(season_idx), 'omitnan');
    Wind_generation_kWh(s) = mean(Wind_gen_all(season_idx), 'omitnan');
end

Renewable_generation_summary = table( ...
    Season, ...
    round(PV_generation_kWh, 3), ...
    round(Wind_generation_kWh, 3), ...
    'VariableNames', {'Season', 'PV_generation_kWh', 'Wind_generation_kWh'});

disp(' ');
disp('Seasonal renewable generation summary (mean daily generation):');
disp(Renewable_generation_summary);

writetable(Renewable_generation_summary, 'seasonal_pv_wind_generation_summary.xlsx');

%% =========================================================
%  Combined 4x2 figure for seasonal charging/discharging
%% =========================================================
figure;
tiledlayout(4, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

for s = 1:numel(season_names)

    SEASON_now = season_names{s};
    season_idx = valid_all & (Season_label' == string(SEASON_now));

    if ~any(season_idx)
        continue;
    end

    Pcha_da_mean_season   = mean(Pcha_dayahead_all(:, season_idx), 2, 'omitnan');
    Pcha_mpc_mean_season  = mean(Pcha_mpc_all(:, season_idx), 2, 'omitnan');
    Pcha_rule_mean_season = mean(Pcha_rule_all(:, season_idx), 2, 'omitnan');

    Pdis_da_mean_season   = mean(Pdis_dayahead_all(:, season_idx), 2, 'omitnan');
    Pdis_mpc_mean_season  = mean(Pdis_mpc_all(:, season_idx), 2, 'omitnan');
    Pdis_rule_mean_season = mean(Pdis_rule_all(:, season_idx), 2, 'omitnan');

    nexttile;
    plot(1:T, Pcha_da_mean_season, '-o', 'LineWidth', 1.0); hold on;
    plot(1:T, Pcha_mpc_mean_season, '-s', 'LineWidth', 1.0);
    plot(1:T, Pcha_rule_mean_season, '-^', 'LineWidth', 1.0);
    xlabel('Time of day');
    ylabel('Charging (kW)');
    title([upper(SEASON_now(1)), SEASON_now(2:end), ' - Mean charging']);
    xticks(1:tick_step:T);
    xticklabels(time_lbl_48(1:tick_step:T));
    xtickangle(45);
    grid on;
    if s == 1
        legend('Day-ahead MILP', 'MPC', 'Rule-based', 'Location', 'best');
    end

    nexttile;
    plot(1:T, Pdis_da_mean_season, '-o', 'LineWidth', 1.0); hold on;
    plot(1:T, Pdis_mpc_mean_season, '-s', 'LineWidth', 1.0);
    plot(1:T, Pdis_rule_mean_season, '-^', 'LineWidth', 1.0);
    xlabel('Time of day');
    ylabel('Discharging (kW)');
    title([upper(SEASON_now(1)), SEASON_now(2:end), ' - Mean discharging']);
    xticks(1:tick_step:T);
    xticklabels(time_lbl_48(1:tick_step:T));
    xtickangle(45);
    grid on;
    if s == 1
        legend('Day-ahead MILP', 'MPC', 'Rule-based', 'Location', 'best');
    end
end

sgtitle('Seasonal mean charging and discharging comparison (4x2)');

%% =========================================================
%  Overall cost summary table
%% =========================================================
cost_no_control = F_nocontrol_all(valid_all);
cost_dayahead   = F_dayahead_all(valid_all);
cost_mpc        = F_mpc_all(valid_all);
cost_rule       = F_rule_all(valid_all);

saving_no_control = zeros(size(cost_no_control));
saving_dayahead   = cost_no_control - cost_dayahead;
saving_mpc        = cost_no_control - cost_mpc;
saving_rule       = cost_no_control - cost_rule;

mean_no_control = mean(cost_no_control, 'omitnan');

Strategy = {
    'No control';
    'Day-ahead MILP';
    'MPC';
    'Rule-based'
};

Mean_Cost_pence = [
    mean(cost_no_control, 'omitnan');
    mean(cost_dayahead,   'omitnan');
    mean(cost_mpc,        'omitnan');
    mean(cost_rule,       'omitnan')
];

Std_Cost_pence = [
    std(cost_no_control, 0, 'omitnan');
    std(cost_dayahead,   0, 'omitnan');
    std(cost_mpc,        0, 'omitnan');
    std(cost_rule,       0, 'omitnan')
];

Mean_Saving_pence = [
    mean(saving_no_control, 'omitnan');
    mean(saving_dayahead,   'omitnan');
    mean(saving_mpc,        'omitnan');
    mean(saving_rule,       'omitnan')
];

Saving_percent = Mean_Saving_pence ./ mean_no_control * 100;

Mean_Saving_display = string(round(Mean_Saving_pence, 2));
Saving_percent_display = string(round(Saving_percent, 3));

Mean_Saving_display(1) = "N/A";
Saving_percent_display(1) = "N/A";

Daily_Load_kWh_all_valid = sum(Load_kWh_all_runs(:, valid_all), 1, 'omitnan');

Mean_Daily_Load_kWh = [
    mean(Daily_Load_kWh_all_valid, 'omitnan');
    mean(Daily_Load_kWh_all_valid, 'omitnan');
    mean(Daily_Load_kWh_all_valid, 'omitnan');
    mean(Daily_Load_kWh_all_valid, 'omitnan')
];

Overall_summary = table( ...
    Strategy, ...
    round(Mean_Cost_pence, 3), ...
    round(Std_Cost_pence, 3), ...
    Mean_Saving_display, ...
    Saving_percent_display, ...
    round(Mean_Daily_Load_kWh, 3), ...
    'VariableNames', {'Strategy', 'Mean_Cost_pence', 'Std_Cost_pence', ...
                      'Mean_Saving_pence', 'Saving_percent', ...
                      'Mean_Daily_Load_kWh'});

disp(' ');
disp('Overall cost reduction summary across all seasons:');
disp(Overall_summary);

writetable(Overall_summary, 'overall_cost_summary_all_seasons.xlsx');

%% =========================================================
%  Overall cost comparison plots
%% =========================================================
cost_matrix = [ ...
    cost_no_control', ...
    cost_dayahead', ...
    cost_mpc', ...
    cost_rule' ];

figure;
bar(cost_matrix);
xlabel('Randomly sampled daily scenario index');
ylabel('Daily cost (pence)');
title('Daily cost comparison across all seasons');
legend('No control', 'Day-ahead MILP', 'MPC', 'Rule-based', 'Location', 'best');
grid on;

figure;
bar(Mean_Cost_pence);
set(gca, 'XTickLabel', {'No control','Day-ahead','MPC','Rule-based'});
ylabel('Mean daily cost (pence)');
title('Overall mean daily cost across all seasons');
grid on;

saving_matrix = [ ...
    saving_dayahead', ...
    saving_mpc', ...
    saving_rule' ];

figure;
bar(saving_matrix);
xlabel('Randomly sampled daily scenario index');
ylabel('Saving compared with no control (pence)');
title('Cost saving comparison across all seasons');
legend('Day-ahead MILP', 'MPC', 'Rule-based', 'Location', 'best');
grid on;

figure;
bar(Saving_percent);
set(gca, 'XTickLabel', {'No control','Day-ahead','MPC','Rule-based'});
ylabel('Saving (%)');
title('Overall saving percentage compared with no control');
grid on;

%% =========================================================
%  Mean power profiles across all valid runs
%% =========================================================
Pcha_da_mean   = mean(Pcha_dayahead_all(:, valid_all), 2, 'omitnan');
Pcha_mpc_mean  = mean(Pcha_mpc_all(:, valid_all), 2, 'omitnan');
Pcha_rule_mean = mean(Pcha_rule_all(:, valid_all), 2, 'omitnan');

figure;
plot(1:T, Pcha_da_mean, '-o', 'LineWidth', 1.2); hold on;
plot(1:T, Pcha_mpc_mean, '-s', 'LineWidth', 1.2);
plot(1:T, Pcha_rule_mean, '-^', 'LineWidth', 1.2);
xlabel('Time of day');
ylabel('Mean charging power (kW)');
title('Mean charging power comparison across all seasons');
legend('Day-ahead MILP', 'MPC', 'Rule-based', 'Location', 'best');
xticks(1:tick_step:T);
xticklabels(time_lbl_48(1:tick_step:T));
xtickangle(45);
grid on;

Pdis_da_mean   = mean(Pdis_dayahead_all(:, valid_all), 2, 'omitnan');
Pdis_mpc_mean  = mean(Pdis_mpc_all(:, valid_all), 2, 'omitnan');
Pdis_rule_mean = mean(Pdis_rule_all(:, valid_all), 2, 'omitnan');

figure;
plot(1:T, Pdis_da_mean, '-o', 'LineWidth', 1.2); hold on;
plot(1:T, Pdis_mpc_mean, '-s', 'LineWidth', 1.2);
plot(1:T, Pdis_rule_mean, '-^', 'LineWidth', 1.2);
xlabel('Time of day');
ylabel('Mean discharging power (kW)');
title('Mean discharging power comparison across all seasons');
legend('Day-ahead MILP', 'MPC', 'Rule-based', 'Location', 'best');
xticks(1:tick_step:T);
xticklabels(time_lbl_48(1:tick_step:T));
xtickangle(45);
grid on;

Pbuy_da_mean   = mean(Pbuy_dayahead_all(:, valid_all), 2, 'omitnan');
Pbuy_mpc_mean  = mean(Pbuy_mpc_all(:, valid_all), 2, 'omitnan');
Pbuy_rule_mean = mean(Pbuy_rule_all(:, valid_all), 2, 'omitnan');

figure;
plot(1:T, Pbuy_da_mean, '-o', 'LineWidth', 1.2); hold on;
plot(1:T, Pbuy_mpc_mean, '-s', 'LineWidth', 1.2);
plot(1:T, Pbuy_rule_mean, '-^', 'LineWidth', 1.2);
xlabel('Time of day');
ylabel('Mean grid import power (kW)');
title('Mean grid import comparison across all seasons');
legend('Day-ahead MILP', 'MPC', 'Rule-based', 'Location', 'best');
xticks(1:tick_step:T);
xticklabels(time_lbl_48(1:tick_step:T));
xtickangle(45);
grid on;

Psell_da_mean   = mean(Psell_dayahead_all(:, valid_all), 2, 'omitnan');
Psell_mpc_mean  = mean(Psell_mpc_all(:, valid_all), 2, 'omitnan');
Psell_rule_mean = mean(Psell_rule_all(:, valid_all), 2, 'omitnan');

figure;
plot(1:T, Psell_da_mean, '-o', 'LineWidth', 1.2); hold on;
plot(1:T, Psell_mpc_mean, '-s', 'LineWidth', 1.2);
plot(1:T, Psell_rule_mean, '-^', 'LineWidth', 1.2);
xlabel('Time of day');
ylabel('Mean grid export power (kW)');
title('Mean grid export comparison across all seasons');
legend('Day-ahead MILP', 'MPC', 'Rule-based', 'Location', 'best');
xticks(1:tick_step:T);
xticklabels(time_lbl_48(1:tick_step:T));
xtickangle(45);
grid on;

%% =========================================================
%  SoC comparison, all in p.u.
%% =========================================================
SOC_da_mean   = mean(SOC_dayahead_all(:, valid_all), 2, 'omitnan');
SOC_mpc_mean  = mean(SOC_mpc_all(:, valid_all), 2, 'omitnan');
SOC_rule_mean = mean(SOC_rule_all(:, valid_all), 2, 'omitnan');

figure;
plot(0:T, SOC_da_mean, '-o', 'LineWidth', 1.2); hold on;
plot(0:T, SOC_mpc_mean, '-s', 'LineWidth', 1.2);
plot(0:T, SOC_rule_mean, '-^', 'LineWidth', 1.2);
xlabel('Time of day');
ylabel('Mean SoC (p.u.)');
title('Mean SoC trajectory comparison across all seasons');
legend('Day-ahead MILP', 'MPC', 'Rule-based', 'Location', 'best');
xticks(0:tick_step:T);
xticklabels(time_lbl_49(1:tick_step:end));
xtickangle(45);
grid on;

toc;

%% =========================================================
%  Local functions
%% =========================================================

function tbl = addDayKeyAndSlot(tbl, timeVarName)
    dt_local = tbl.(timeVarName);
    tbl.DayKey = string(compose("%02d-%02d", month(dt_local), day(dt_local)));
    tbl.Slot   = hour(dt_local) * 2 + minute(dt_local) / 30 + 1;
end

function keys = getCompleteDayKeys(dayKey)
    [u, ~, ic] = unique(dayKey);
    cnt = accumarray(ic, 1);
    keys = u(cnt == 48);
end

%% =========================================================
%  Strategy 1: Day-ahead MILP
%% =========================================================
function [res, ok] = run_dayahead_milp( ...
    Pload_day, Pwt_max_day, Ppv_max_day, price_buy, price_sell, ...
    T, dt, Ubat, SOC_init, SOC_min, SOC_max, ...
    eta_cha, eta_dis, e_bat, Pcha_max, Pdis_max, Pgrid_max, C_stand)

    ok = false;
    res = struct();

    yalmip('clear');
    Constraint = [];

    Pwt   = sdpvar(T,1,'full');
    Ppv   = sdpvar(T,1,'full');
    Pcha  = sdpvar(T,1,'full');
    Pdis  = sdpvar(T,1,'full');
    Pbuy  = sdpvar(T,1,'full');
    Psell = sdpvar(T,1,'full');
    Soc   = sdpvar(T+1,1,'full');

    Cha  = binvar(T,1);
    Dis  = binvar(T,1);
    Buy  = binvar(T,1);
    Sell = binvar(T,1);

    Constraint = [Constraint, ...
        0 <= Pwt <= Pwt_max_day, ...
        0 <= Ppv <= Ppv_max_day];

    Constraint = [Constraint, ...
        0 <= Pcha <= Cha * Pcha_max, ...
        0 <= Pdis <= Dis * Pdis_max, ...
        Cha + Dis <= 1, ...
        SOC_min <= Soc <= SOC_max, ...
        Soc(1) == SOC_init, ...
        Soc(T+1) == Soc(1), ...
        Soc(2:T+1) == Soc(1:T) * (1 - e_bat) + ...
            dt * (eta_cha * Pcha - Pdis / eta_dis) / Ubat];

    Constraint = [Constraint, ...
        0 <= Pbuy  <= Buy  * Pgrid_max, ...
        0 <= Psell <= Sell * Pgrid_max, ...
        Buy + Sell <= 1];

    Constraint = [Constraint, ...
        Pbuy + Pwt + Pdis + Ppv == Psell + Pload_day + Pcha];

    F = sum(price_buy .* Pbuy * dt - price_sell .* Psell * dt) + C_stand;

    ops = sdpsettings('solver','cplex','verbose',0);
    diagnostics = optimize(Constraint, F, ops);

    if diagnostics.problem ~= 0
        return;
    end

    res.Pcha   = value(Pcha);
    res.Pdis   = value(Pdis);
    res.Pbuy   = value(Pbuy);
    res.Psell  = value(Psell);
    res.SOC_pu = value(Soc);
    res.cost   = value(F);

    ok = true;
end

%% =========================================================
%  Strategy 2: MPC
%% =========================================================
function [res, ok] = run_mpc_strategy( ...
    Pload_day, Pwt_day, Ppv_day, price_buy, price_sell, ...
    T, N_H, dt, Ubat, Soc_init, Soc_min, Soc_max, ...
    eta, e_bat, Pcha_max, Pdis_max, Pgrid_max, C_stand)

    ok = false;
    res = struct();

    Soc_real  = Soc_init;
    Soc_traj  = zeros(T+1,1);
    Soc_traj(1) = Soc_real;

    Pcha_act  = zeros(T,1);
    Pdis_act  = zeros(T,1);
    Pbuy_act  = zeros(T,1);
    Psell_act = zeros(T,1);

    cost_mpc = 0;

    terminal_start_slots = 8;

    for t = 1:T

        N = min(N_H, T - t + 1);
        is_last_horizon = (T - t + 1 <= terminal_start_slots);

        f_buy  = price_buy(t:t+N-1);
        f_sell = price_sell(t:t+N-1);

        % Persistence forecast
        f_load = repmat(Pload_day(t), N, 1);
        f_wind = repmat(Pwt_day(t),   N, 1);
        f_pv   = repmat(Ppv_day(t),   N, 1);

        [sol, feasible] = solve_mpc_horizon( ...
            f_load, f_wind, f_pv, f_buy, f_sell, ...
            Soc_real, N, ...
            Pcha_max, Pdis_max, Soc_min, Soc_max, ...
            Pgrid_max, eta, e_bat, dt, ...
            is_last_horizon, Soc_init);

        if ~feasible
            return;
        end

        Pcha_act(t)  = sol.Pcha(1);
        Pdis_act(t)  = sol.Pdis(1);
        Pbuy_act(t)  = sol.Pbuy(1);
        Psell_act(t) = sol.Psell(1);

        cost_mpc = cost_mpc ...
            + price_buy(t)  * Pbuy_act(t)  * dt ...
            - price_sell(t) * Psell_act(t) * dt ...
            + C_stand / T;

        Soc_real = Soc_real * (1 - e_bat) + ...
            dt * (eta * Pcha_act(t) - Pdis_act(t) / eta);

        Soc_real = max(Soc_min, min(Soc_max, Soc_real));
        Soc_traj(t+1) = Soc_real;

    end

    res.Pcha    = Pcha_act;
    res.Pdis    = Pdis_act;
    res.Pbuy    = Pbuy_act;
    res.Psell   = Psell_act;
    res.SOC_kWh = Soc_traj;
    res.cost    = cost_mpc;

    ok = true;
end

function [sol, feasible] = solve_mpc_horizon( ...
    f_load, f_wind, f_pv, f_buy, f_sell, soc_init, N, ...
    Pcha_max, Pdis_max, Soc_min, Soc_max, Pgrid_max, eta, e_bat, dt, ...
    is_last_horizon, Soc_target)

    feasible = false;
    sol = struct();

    yalmip('clear');
    Constraint = [];

    Pwt   = sdpvar(N,1,'full');
    Ppv   = sdpvar(N,1,'full');
    Pcha  = sdpvar(N,1,'full');
    Pdis  = sdpvar(N,1,'full');
    Soc   = sdpvar(N+1,1,'full');
    Pbuy  = sdpvar(N,1,'full');
    Psell = sdpvar(N,1,'full');

    Cha  = binvar(N,1);
    Dis  = binvar(N,1);
    Buy  = binvar(N,1);
    Sell = binvar(N,1);

    Constraint = [Constraint, ...
        0 <= Pwt <= f_wind, ...
        0 <= Ppv <= f_pv];

    Constraint = [Constraint, ...
        0 <= Pcha <= Cha * Pcha_max, ...
        0 <= Pdis <= Dis * Pdis_max, ...
        Cha + Dis <= 1, ...
        Soc_min <= Soc <= Soc_max, ...
        Soc(1) == soc_init, ...
        Soc(2:N+1) == Soc(1:N) * (1 - e_bat) + ...
            dt * (eta * Pcha - Pdis / eta)];

    if is_last_horizon
        Constraint = [Constraint, Soc(N+1) == Soc_target];
    end

    Constraint = [Constraint, ...
        0 <= Pbuy  <= Buy  * Pgrid_max, ...
        0 <= Psell <= Sell * Pgrid_max, ...
        Buy + Sell <= 1];

    Constraint = [Constraint, ...
        Pbuy + Pwt + Pdis + Ppv == Psell + f_load + Pcha];

    Obj = sum(f_buy .* Pbuy * dt - f_sell .* Psell * dt);

    ops = sdpsettings('solver','cplex','verbose',0);
    diagnostics = optimize(Constraint, Obj, ops);

    if diagnostics.problem ~= 0
        return;
    end

    sol.Pcha  = value(Pcha);
    sol.Pdis  = value(Pdis);
    sol.Pbuy  = value(Pbuy);
    sol.Psell = value(Psell);

    feasible = true;
end

%% =========================================================
%  Strategy 3: Rule-based baseline
%% =========================================================
function res = run_rule_based_baseline( ...
    Pload_day, Pwt_day, Ppv_day, price_buy, price_sell, ...
    T, dt, Ubat, SOC_init, SOC_min, SOC_max, SOC_peak_target, ...
    eta_cha, eta_dis, e_bat, Pcha_max, Pdis_max, Pgrid_max, C_stand, ...
    peak_slots, peak_windows)

    SOC = nan(T+1,1);
    SOC(1) = SOC_init;

    Pcha  = zeros(T,1);
    Pdis  = zeros(T,1);
    Pbuy  = zeros(T,1);
    Psell = zeros(T,1);

    for t = 1:T

        Pren = Pwt_day(t) + Ppv_day(t);

        if ismember(t, peak_slots)

            Pcha(t) = 0;

            if SOC(t) > SOC_peak_target

                available_above_target = (SOC(t) - SOC_peak_target) * Ubat;

                current_window = [];

                for pw = 1:numel(peak_windows)
                    if ismember(t, peak_windows{pw})
                        current_window = peak_windows{pw};
                        break;
                    end
                end

                remaining_peak_slots = sum(current_window >= t);

                Pdis_peak_target = available_above_target * eta_dis / ...
                                   (remaining_peak_slots * dt);

                Pdis_soc_limit = available_above_target * eta_dis / dt;

                net_without_batt = Pren - Pload_day(t);

                existing_export = max(0, net_without_batt);
                export_room = max(0, Pgrid_max - existing_export);

                load_deficit = max(0, -net_without_batt);

                Pdis_grid_limit = load_deficit + export_room;

                Pdis(t) = min([Pdis_peak_target, Pdis_max, Pdis_soc_limit, Pdis_grid_limit]);

            else
                Pdis(t) = 0;
            end

            net_after_batt = Pren + Pdis(t) - Pload_day(t);

            if net_after_batt >= 0
                Psell(t) = min(net_after_batt, Pgrid_max);
                Pbuy(t) = 0;
            else
                Pbuy(t) = min(-net_after_batt, Pgrid_max);
                Psell(t) = 0;
            end

        else

            if Pren >= Pload_day(t)

                Psurplus = Pren - Pload_day(t);

                if SOC(t) < SOC_max
                    Pcha_soc_limit = (SOC_max - SOC(t)) * Ubat / (dt * eta_cha);
                    Pcha(t) = min([Psurplus, Pcha_max, Pcha_soc_limit]);
                else
                    Pcha(t) = 0;
                end

                Pdis(t) = 0;

                Psell_raw = max(0, Psurplus - Pcha(t));
                Psell(t) = min(Psell_raw, Pgrid_max);

                Pbuy(t) = 0;

            else

                Pdef = Pload_day(t) - Pren;

                Pcha(t) = 0;
                Pdis(t) = 0;
                Psell(t) = 0;

                Pbuy(t) = min(Pdef, Pgrid_max);

            end
        end

        SOC(t+1) = SOC(t) * (1 - e_bat) + ...
                   dt/Ubat * (eta_cha * Pcha(t) - Pdis(t)/eta_dis);

        SOC(t+1) = min(max(SOC(t+1), SOC_min), SOC_max);

    end

    F_rule = sum(price_buy .* Pbuy * dt - price_sell .* Psell * dt) + C_stand;

    res.Pcha   = Pcha;
    res.Pdis   = Pdis;
    res.Pbuy   = Pbuy;
    res.Psell  = Psell;
    res.SOC_pu = SOC;
    res.cost   = F_rule;
end

