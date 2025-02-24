
# SET-UP ------------------------------------------------------------------
library(tidyverse)
library(tidymodels)
library(lubridate)
library(here)
library(janitor)
library(nflreadr)
library(ffscrapr)

setwd(here())

get_age <- function(from_date,to_date = lubridate::now(),dec = FALSE){
  if(is.character(from_date)) from_date <- lubridate::as_date(from_date)
  if(is.character(to_date))   to_date   <- lubridate::as_date(to_date)
  if (dec) { age <- lubridate::interval(start = from_date, end = to_date)/(lubridate::days(365)+lubridate::hours(6))
  } else   { age <- lubridate::year(lubridate::as.period(lubridate::interval(start = from_date, end = to_date)))}
  round(age,2)
}

filenames <- list.files("./models", pattern="fit", full.names=TRUE)
obj_names <- str_remove_all(filenames,"./models/|.RDS")
models <- map(filenames, readRDS) %>% set_names(obj_names)

start_year <- 2014

nflfastr_rosters <-
  nflfastR::fast_scraper_roster(2021) %>%
  dplyr::select(season, gsis_id, position, full_name, birth_date, sportradar_id) %>% 
  dplyr::mutate(position = dplyr::if_else(position %in% c("HB","FB"), "RB", position))

future::plan("multisession")
# season_ids <- nflfastR::fast_scraper_schedules(2021) %>% pull(game_id)
# nfl_pbp <- nflfastR::build_nflfastR_pbp(season_ids)


# RUSHING PREDICTIONS -----------------------------------------------------
rush_df <-
  nflfastR::load_pbp(2021) %>% 
  # nfl_pbp %>% 
  # arrow::open_dataset("~/Documents/DynastyProcess/db/data/nflfastr_pbp") %>% 
  # dplyr::filter(season >= start_year) %>% 
  # dplyr::collect() %>%
  # Restrict to rush plays
  dplyr::filter(play_type == "run", !str_detect(desc, "kneel|Aborted")) %>%
  dplyr::left_join(nflfastr_rosters, by = c("fantasy_player_id" = "gsis_id", "season"), na_matches = "never") %>%
  dplyr::filter(position %in% c("QB","RB","WR","TE")) %>%
  dplyr::mutate(game_month = month(game_date),
                game_month = if_else(game_month < 3, 12, game_month),
                game_week = week(game_date),
                game_week = if_else(game_week <= 30, 53, game_week),
                game_wday = as.character(wday(game_date, label = TRUE)),
                game_wday = case_when(game_wday %in% c("Tue","Wed","Fri","Sat") ~ "Other", TRUE ~ game_wday),
                game_time = hour(hms(start_time)),
                implied_total = case_when(posteam_type == "away" & spread_line<=0 ~ (total_line+spread_line)/2 - spread_line,
                                          posteam_type == "away" & spread_line>0 ~ (total_line-spread_line)/2,
                                          posteam_type == "home" & spread_line>0 ~ (total_line+spread_line)/2 - spread_line,
                                          posteam_type == "home" & spread_line<=0 ~ (total_line-spread_line)/2),
                rusher_age = get_age(birth_date, game_date, dec = TRUE),
                #Two Point Conversion fixes
                two_point_converted = case_when(two_point_conv_result == "success" ~ 1,
                                                is.na(two_point_conv_result) & str_detect(desc, "ATTEMPT SUCCEEDS") ~ 1,
                                                TRUE ~ 0),
                score = if_else(rush_touchdown == 1 | two_point_converted == 1, 1, 0),
                rushing_yards = case_when(is.na(rushing_yards) & two_point_attempt == 1 & two_point_converted == 1 ~ yardline_100,
                                          is.na(rushing_yards) & two_point_attempt == 1 & two_point_converted == 0 ~ 0 ,
                                          TRUE ~ rushing_yards),
                down = if_else(two_point_attempt == 1, 4, down),
                surface = if_else(surface == "grass", "grass", "turf"),
                run_location = case_when(!is.na(run_location) ~ run_location,
                                         str_detect(desc, " left") ~ "left",
                                         str_detect(desc, " right") ~ "right",
                                         str_detect(desc, " middle") ~ "middle",
                                         TRUE ~ "unk"),
                run_gap = case_when(!is.na(run_gap) ~ run_gap,
                                    run_location == "middle" ~ "guard",
                                    str_detect(desc, " end") ~ "end",
                                    str_detect(desc, " tackle") ~ "tackle",
                                    str_detect(desc, " guard") ~ "guard",
                                    str_detect(desc, " middle") ~ "guard",
                                    TRUE ~ "unk"),
                temp = case_when(roof %in% c("closed", "dome") ~ 68L,
                                 is.na(temp) ~ 60L,
                                 TRUE ~ temp),
                wind = case_when(roof %in% c("closed", "dome") ~ 0L,
                                 is.na(wind) ~ 8L,
                                 TRUE ~ wind),
                rushing_fantasy_points = 6*rush_touchdown + 2*two_point_converted + 0.1*rushing_yards - 2*fumble_lost,
                season = factor(season, levels = as.character(c(2001:2020)), ordered = TRUE),
                week = factor(week, levels = as.character(c(1:21)), ordered = TRUE),
                game_month = factor(game_month, levels = as.character(c(9:12)), ordered = TRUE),
                game_week = factor(game_week, levels = as.character(c(36:53)), ordered = TRUE),
                game_time = factor(game_time, levels = as.character(c(9:23)), ordered = TRUE),
                qtr = factor(qtr, levels = as.character(c(1:6)), ordered = TRUE),
                down = factor(down, levels = as.character(c(1:4)), ordered = TRUE),
                goal_to_go = factor(goal_to_go, levels = as.character(c(0,1))),
                shotgun = factor(shotgun, levels = as.character(c(0,1))),
                no_huddle = factor(no_huddle, levels = as.character(c(0,1))),
                qb_dropback = factor(qb_dropback, levels = as.character(c(0,1))),
                qb_scramble = factor(qb_scramble, levels = as.character(c(0,1))),
                two_point_attempt = factor(two_point_attempt, levels = as.character(c(0,1))),
                score = factor(score, levels = as.character(c(0,1))),
                first_down = factor(first_down, levels = as.character(c(0,1))),
                run_gap_dir = paste(run_location, run_gap, sep = "_")) %>%
  dplyr::filter(run_gap_dir %in% c("left_end", "left_tackle", "left_guard", "middle_guard",
                                   "right_guard", "right_tackle", "right_end")) %>%
  dplyr::bind_cols(predict(models$fit_rush_yards, new_data = .)) %>% 
  dplyr::rename(rushing_yards_exp = .pred) %>%
  dplyr::bind_cols(predict(models$fit_rush_tds, new_data = ., type = "prob")) %>%
  dplyr::rename(rushing_td_exp = .pred_1) %>%
  dplyr::select(-.pred_0) %>% 
  dplyr::bind_cols(predict(models$fit_rush_fds, new_data = ., type = "prob")) %>%
  dplyr::rename(rushing_fd_exp = .pred_1) %>% 
  dplyr::transmute(season = substr(game_id, 1, 4),
                   week,
                   game_id,
                   play_id = as.factor(play_id),
                   play_description = desc,
                   player_id = fantasy_player_id,
                   full_name,
                   position,
                   posteam,
                   player_type = "rush",
                   attempt = 1, 
                   yards_gained = rushing_yards,
                   yards_gained_exp = rushing_yards_exp,
                   # score,
                   # rushing_score_exp = rushing_td_exp,
                   touchdown = rush_touchdown,
                   touchdown_exp = if_else(two_point_attempt == 1, 0, rushing_td_exp),
                   two_point_conv = two_point_converted,
                   two_point_conv_exp = if_else(two_point_attempt == 1, rushing_td_exp, 0),
                   first_down = as.numeric(first_down) - 1,
                   first_down_exp = rushing_fd_exp,
                   fantasy_points = rushing_fantasy_points,
                   fantasy_points_exp = 0.1*rushing_yards_exp + if_else(two_point_attempt == 1,
                                                                        2*rushing_td_exp,
                                                                        6*rushing_td_exp),
                   fumble_lost)


# RECEIVING PREDICTIONS ---------------------------------------------------
pass_df <-
  nflfastR::load_pbp(2021) %>% 
  # nfl_pbp %>% 
  # arrow::open_dataset("~/Documents/DynastyProcess/db/data/nflfastr_pbp") %>% 
  # dplyr::filter(season >= start_year) %>% 
  # dplyr::collect() %>%
  # Restrict to rush plays
  dplyr::filter(play_type == "pass", !str_detect(desc, "Aborted")) %>%
  dplyr::left_join(select(nflfastr_rosters,
                          gsis_id,
                          season,
                          passer_position = position,
                          passer_full_name = full_name,
                          passer_birth_date = birth_date),
                   by = c("passer_player_id" = "gsis_id", "season"),
                   na_matches = "never") %>%
  dplyr::left_join(select(nflfastr_rosters,
                          gsis_id,
                          season,
                          receiver_position = position,
                          receiver_full_name = full_name,
                          receiver_birth_date = birth_date),
                   by = c("receiver_player_id" = "gsis_id", "season"),
                   na_matches = "never") %>%
  dplyr::filter(passer_position %in% c("QB","RB","WR","TE")) %>% 
  dplyr::filter(receiver_position %in% c("QB","RB","WR","TE")) %>%
  dplyr::mutate(game_month = month(game_date),
                game_month = if_else(game_month < 3, 12, game_month),
                game_week = week(game_date),
                game_week = if_else(game_week <= 30, 53, game_week),
                game_wday = as.character(wday(game_date, label = TRUE)),
                game_wday = case_when(game_wday %in% c("Tue","Wed","Fri","Sat") ~ "Other",
                                      TRUE ~ game_wday),
                game_time = hour(hms(start_time)),
                implied_total = case_when(posteam_type == "away" & spread_line<=0 ~ (total_line+spread_line)/2 - spread_line,
                                          posteam_type == "away" & spread_line>0 ~ (total_line-spread_line)/2,
                                          posteam_type == "home" & spread_line>0 ~ (total_line+spread_line)/2 - spread_line,
                                          posteam_type == "home" & spread_line<=0 ~ (total_line-spread_line)/2),
                passer_age = get_age(passer_birth_date, game_date, dec = TRUE),
                receiver_age = get_age(receiver_birth_date, game_date, dec = TRUE),
                passer_position = if_else(passer_position != "QB", "non-QB", passer_position),
                #Two Point Conversion fixes
                two_point_converted = case_when(two_point_conv_result == "success" ~ 1,
                                                is.na(two_point_conv_result) & str_detect(desc, "ATTEMPT SUCCEEDS") ~ 1,
                                                TRUE ~ 0),
                score = if_else(pass_touchdown == 1 | two_point_converted == 1, 1, 0),
                receiving_yards = case_when(is.na(receiving_yards) & two_point_attempt == 1 & two_point_converted == 1 ~ yardline_100,
                                            is.na(receiving_yards) & two_point_attempt == 1 & two_point_converted == 0 ~ 0,
                                            complete_pass == 0 ~ 0,
                                            TRUE ~ receiving_yards),
                air_yards = if_else(two_point_attempt == 1, yardline_100, air_yards),
                complete_pass = if_else(two_point_attempt == 1 & grepl("is complete", desc), 1, complete_pass),
                pass_complete = if_else(complete_pass == 1, "complete", "incomplete"),
                down = if_else(two_point_attempt == 1, 4, down),
                xpass = if_else(two_point_attempt == 1, 0.75, xpass),
                distance_to_sticks = air_yards - ydstogo,
                distance_to_endzone = air_yards - yardline_100,
                
                #Data Cleaning
                surface = if_else(surface == "grass", "grass", "turf"),
                pass_location = case_when(!is.na(pass_location) ~ pass_location,
                                          str_detect(desc, " left") ~ "left",
                                          str_detect(desc, " right") ~ "right",
                                          str_detect(desc, " middle") ~ "middle",
                                          TRUE ~ "unk"),
                temp = case_when(roof %in% c("closed", "dome") ~ 68L,
                                 is.na(temp) ~ 60L,
                                 TRUE ~ temp),
                wind = case_when(roof %in% c("closed", "dome") ~ 0L,
                                 is.na(wind) ~ 8L,
                                 TRUE ~ wind),
                receiving_fantasy_points = 6*pass_touchdown + 2*two_point_converted  + 0.1*receiving_yards - 2*fumble_lost + complete_pass,
                passing_fantasy_points =  4*pass_touchdown + 2*two_point_converted  + 0.04*receiving_yards - 2*fumble_lost - 2*interception,
                season = factor(season, levels = as.character(c(2001:2020)), ordered = TRUE),
                week = factor(week, levels = as.character(c(1:21)), ordered = TRUE),
                game_month = factor(game_month, levels = as.character(c(9:12)), ordered = TRUE),
                game_week = factor(game_week, levels = as.character(c(36:53)), ordered = TRUE),
                game_time = factor(game_time, levels = as.character(c(9:23)), ordered = TRUE),
                qtr = factor(qtr, levels = as.character(c(1:6)), ordered = TRUE),
                down = factor(down, levels = as.character(c(1:4)), ordered = TRUE),
                goal_to_go = factor(goal_to_go, levels = as.character(c(0,1))),
                shotgun = factor(shotgun, levels = as.character(c(0,1))),
                no_huddle = factor(no_huddle, levels = as.character(c(0,1))),
                qb_dropback = factor(qb_dropback, levels = as.character(c(0,1))),
                qb_scramble = factor(qb_scramble, levels = as.character(c(0,1))),
                two_point_attempt = factor(two_point_attempt, levels = as.character(c(0,1))),
                score = factor(score, levels = as.character(c(0,1))),
                first_down = factor(first_down, levels = as.character(c(0,1))),
                pass_complete = factor(pass_complete, levels = c("complete", "incomplete"), ordered = TRUE),
                interception = factor(interception, levels = as.character(c(0,1))),
                qb_hit = factor(qb_hit, levels = as.character(c(0,1)))) %>%
  dplyr::filter(!is.na(air_yards)) %>%
  dplyr::bind_cols(predict(models$fit_pass_completion, new_data = ., type = "prob")) %>% 
  dplyr::rename(pass_completion_exp = .pred_complete) %>%
  dplyr::bind_cols(predict(models$fit_pass_yards, new_data = .)) %>% 
  dplyr::rename(receiving_yards_exp = .pred) %>%
  dplyr::bind_cols(predict(models$fit_pass_td, new_data = ., type = "prob")) %>%
  dplyr::rename(rec_td_exp = .pred_1) %>%
  dplyr::select(-.pred_0) %>% 
  dplyr::bind_cols(predict(models$fit_pass_fd, new_data = ., type = "prob")) %>%
  dplyr::rename(rec_fd_exp = .pred_1) %>%
  dplyr::select(-.pred_0) %>%
  dplyr::bind_cols(predict(models$fit_pass_int, new_data = ., type = "prob")) %>%
  dplyr::rename(passing_int_exp = .pred_1) %>%
  dplyr::select(-.pred_0) %>% 
  
  dplyr::mutate(rec_td_exp = if_else(air_yards == yardline_100, pass_completion_exp, rec_td_exp)) %>% 
                
  dplyr::transmute(season = substr(game_id, 1, 4),
                   week,
                   game_id,
                   play_id = as.factor(play_id),
                   play_description = desc,
                   
                   # cp, xyac_mean_yardage, xyac_median_yardage,
                   # qtr, yardline_100, drive, two_point_attempt, distance_to_endzone,
                   # fantasy_player_id,
                   # full_name,
                   # position,
                   posteam,
                   
                   pass.player_id = passer_player_id,
                   pass.full_name = passer_full_name,
                   pass.position = passer_position,
                   
                   rec.player_id = receiver_player_id,
                   rec.full_name = receiver_full_name,
                   rec.position = receiver_position,
                   
                   attempt = 1,
                   air_yards,
                   complete_pass,
                   complete_pass_exp = pass_completion_exp,
                   
                   yards_gained = receiving_yards,
                   yards_gained_exp = receiving_yards_exp,
                   
                   touchdown = pass_touchdown,
                   touchdown_exp = if_else(two_point_attempt == 1, 0, rec_td_exp),
                   two_point_conv = two_point_converted,
                   two_point_conv_exp = if_else(two_point_attempt == 1, rec_td_exp, 0),
                   first_down = as.numeric(first_down)  - 1,
                   first_down_exp = rec_fd_exp,
                   interception = as.numeric(interception) - 1,
                   interception_exp = passing_int_exp,
                   fumble_lost)

# rmse_vec(pass_df$cp, pass_df$complete_pass)
# rmse_vec(pass_df$complete_pass_exp, pass_df$complete_pass)
# corrr::correlate(pass_df$cp, pass_df$complete_pass)
# corrr::correlate(pass_df$complete_pass_exp, pass_df$complete_pass)
# 
# pass_df %>% 
#   pivot_longer(cols = c(cp, complete_pass_exp, complete_pass)) %>% 
#   ggplot(aes(x = air_yards, y = value, color = name, group = name)) +
#   geom_point() +
#   geom_smooth(se = FALSE) +
#   theme_minimal()
# 
# pass_df %>% 
#   ggplot(aes(x = cp, y = complete_pass_exp)) +
#   geom_point() +
#   geom_abline(color = "red") + 
#   geom_smooth(se = FALSE) +
#   theme_minimal() +
#   facet_wrap(~complete_pass)
# 
# pass_df %>% 
#   filter(complete_pass_exp <= 0.10) %>% 
#   view()

# Investigate Josh Allen
# josh_allen <- pass_df %>%
#   filter(pass.full_name == "Jameis Winston", week == 7) %>%
#   select(play_description, pass.full_name, rec.full_name, air_yards,
#          complete_pass, complete_pass_exp, touchdown, touchdown_exp) %>%
#   mutate(across(contains("exp"), ~round(.x, 3))) %>%
#   view()

pass_df_pivot <- 
  pass_df %>% 
  pivot_longer(cols = c(pass.player_id, pass.full_name, pass.position, 
                        rec.player_id, rec.full_name, rec.position),
               names_to = c("player_type", ".value"),
               names_sep = "\\.") %>% 
  mutate(fantasy_points_exp = if_else(player_type == "rec",
                                      0.1*yards_gained_exp + complete_pass_exp + 6*touchdown_exp + 2*two_point_conv_exp,
                                      0.04*yards_gained_exp - 2*interception_exp + 4*touchdown_exp + 2*two_point_conv_exp),
         fantasy_points = if_else(player_type == "rec",
                                  6*touchdown + 2*two_point_conv  + 0.1*yards_gained - 2*fumble_lost + complete_pass,
                                  4*touchdown + 2*two_point_conv  + 0.04*yards_gained - 2*fumble_lost - 2*interception))

combined_df <- 
  pass_df_pivot %>% 
  bind_rows(rush_df) %>% 
  pivot_wider(id_cols = c(season, posteam, week, game_id, player_id, full_name, position),
              names_from = player_type,
              names_glue = "{player_type}_{.value}",
              values_fn = sum,
              values_from = where(is.numeric)
              ) %>%
  remove_empty(which = "cols") %>% 
  mutate(across(.cols = where(is.numeric),
                .fns =  ~replace_na(.x, 0)),
         across(.cols = where(is.numeric),
                .fns =  ~round(.x, 2))) %>% 
  rowwise() %>%
  mutate(total_yards_gained = sum(across(ends_with("yards_gained"), sum)),
         total_yards_gained_exp = sum(across(ends_with("yards_gained_exp"), sum)),
         total_touchdown = sum(across(ends_with("touchdown"), sum)),
         total_touchdown_exp = sum(across(ends_with("touchdown_exp"), sum)),
         total_first_down = sum(across(ends_with("first_down"), sum)),
         total_first_down_exp = sum(across(ends_with("first_down_exp"), sum)),
         total_fantasy_points = sum(across(ends_with("fantasy_points"), sum)),
         total_fantasy_points_exp = sum(across(ends_with("fantasy_points_exp"), sum)))

exp_fields <- combined_df %>% select(contains("exp")) %>% colnames() %>% str_remove_all("_exp")

for(f in exp_fields) {
  combined_df[paste0(f,"_diff")] <- combined_df[f]-combined_df[paste0(f,"_exp")]
}


#Pull in snap data
snaps <- load_snap_counts() %>% 
  transmute(game_id, player, team, offense_snaps, offense_pct, pfr_id = pfr_player_id) %>% 
  # left_join(select(load_rosters(), gsis_id, full_name, pfr_id, position), by = "pfr_id") %>% view()
  left_join(select(dp_playerids(), gsis_id, fantasypros_id, pfr_id, position), by = "pfr_id") %>%
  full_join(combined_df, by = c("game_id", "gsis_id" = "player_id")) %>%
  filter(position.x %in% c("QB","RB","WR","TE") | position.y %in% c("QB","RB","WR","TE")) %>% 
  mutate(full_name = coalesce(full_name, player),
         team = coalesce(posteam, team),
         position = coalesce(position.y,position.x),
         season = coalesce(season, substr(game_id,1,4)),
         week = coalesce(as.numeric(week), as.numeric(substr(game_id,6,7))),
         
         across(where(is.numeric), ~replace_na(.x, 0))) %>%
  select(-c(player, pfr_id, position.x, position.y, posteam))
  

  
# arrow::write_parquet(combined_df, "expected_points_2021.pdata")

arrow::write_parquet(snaps, "expected_points_2021.pdata")
              

combined_df %>% select(full_name, week, contains("total")) %>% view()


#checks
pass_df_pivot %>% 
  group_by(player_id, player_type, full_name, position, posteam) %>% 
  summarise(across(where(is.numeric), sum)) %>% 
  mutate(across(where(is.numeric), ~round(.x, 1))) %>%
  view()

rush_df %>%
  group_by(fantasy_player_id, full_name, position) %>% 
  summarise(across(where(is.numeric), sum)) %>% 
  mutate(across(where(is.numeric), ~round(.x, 1))) %>%
  view()

#Plots
library(ggplot2)
library(ggrepel)
#fake plot
ep %>% 
  # group_by(Pos) %>% 
  filter(Pos == "WR") %>% 
  slice_max(order_by = -`ROS ECR`, n = 48) %>% 
  # ungroup() %>% 
  ggplot(aes(x = `ROS ECR`, y = `Total FP Exp`, label = `Player Name`)) +
  geom_point() +
  scale_x_reverse() +
  geom_smooth(se = FALSE, method = "lm") +
  geom_label_repel(force = 5) +
  tantastic::theme_tantastic()
