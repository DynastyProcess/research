

load(file = "models/old_models.rda")

#Split the rush data and aggregate by week
rushdf <- pbp %>% 
  filter(play_type %in% c("run"),
         two_point_attempt == 0,
         season == 2019) %>%
  mutate(TwoPtConv = if_else(two_point_conv_result == 'success', 1, 0, missing = 0),
         RushFP = 6*rush_touchdown + 2*TwoPtConv + 0.1*yards_gained - 2*fumble_lost,
         RushFP1D = 6*rush_touchdown + 2*TwoPtConv + 0.1*yards_gained - 2*fumble_lost + 0.5*first_down_rush,
         logyardline = log(yardline_100),
         yardlinesq = yardline_100*yardline_100,
         run_gap2 = ifelse((play_type == "run" & is.na(run_gap)), "center", as.character(run_gap))
  )

rushdf$eRushTD <- plogis(predict(rushTDMod, rushdf))
rushdf$eRushYD <- predict(rushYDMod, rushdf)
rushdf$eRush1D <- plogis(predict(rush1DMod, rushdf))
rushdf$eRushFP <- predict(rushFPMod, rushdf)
rushdf$eRushFP1D <- predict(rushFP1DMod, rushdf)

weeklyTeamRushDF <- rushdf %>%
  group_by(posteam, week) %>%
  summarise(TeamRushes = sum(rush_attempt, na.rm = TRUE),
            TeamRushYD = sum(yards_gained, na.rm = TRUE),
            TeamRush1D = sum(first_down_rush, na.rm = TRUE),
            TeamRushTD = sum(rush_touchdown, na.rm = TRUE),
            eTeamRushFP = sum(eRushFP, na.rm = TRUE),
            TeamRushFP = sum(RushFP, na.rm = TRUE),
            eTeamRushFP1D = sum(eRushFP1D, na.rm= TRUE),
            TeamRushFP1D = sum(RushFP1D, na.rm = TRUE)
  ) %>%
  ungroup()

weeklyRushDF <- rushdf %>%
  group_by(rusher_player_id, posteam, week) %>%
  summarise(Rushes = sum(rush_attempt, na.rm = TRUE),
            RushYD = sum(yards_gained, na.rm = TRUE),
            Rush1D = sum(first_down_rush, na.rm = TRUE),
            RushTD = sum(rush_touchdown, na.rm = TRUE),
            eRushYD = sum(eRushYD, na.rm = TRUE),
            eTDRush = sum(eRushTD, na.rm = TRUE),
            eRush1D = sum(eRush1D, na.rm = TRUE),
            eRushFP = sum(eRushFP, na.rm = TRUE),
            RushFP = sum(RushFP, na.rm = TRUE),
            RushDiff = (RushFP - eRushFP),            
            eRushFP1D = sum(eRushFP1D, na.rm= TRUE),
            RushFP1D = sum(RushFP1D, na.rm = TRUE),
            RushDiff1D = (RushFP1D - eRushFP1D),
            RushGames = n_distinct(game_id)) %>%
  ungroup()


#Split the rec data and aggregate by week
recdf <- pbp %>% 
  filter(play_type %in% c("pass"),
         sack == 0,
         two_point_attempt == 0,
         season == 2019) %>%
  mutate(TwoPtConv = if_else(two_point_conv_result == 'success', 1, 0, missing = 0),
         RecFP = 6*pass_touchdown + 2*TwoPtConv + 0.1*yards_gained - 2*fumble_lost + complete_pass,
         RecFP1D = 6*pass_touchdown + 2*TwoPtConv + 0.1*yards_gained - 2*fumble_lost + complete_pass+ 0.5*first_down_pass,
         logyardline = log(yardline_100),
         yardlinesq = yardline_100*yardline_100,
         abs_air_yards = abs(air_yards)
  )

recdf$eRecTD <- plogis(predict(recTDMod, recdf))
recdf$eRecYD <- predict(recYDMod, recdf)
recdf$eRec <- plogis(predict(recMod, recdf))
recdf$eRec1D <- plogis(predict(rec1DMod, recdf))
recdf$eRecFP <- predict(recFPMod, recdf)
recdf$eRecFP1D <- predict(recFP1DMod, recdf)

weeklyTeamRecDF <- recdf %>%
  group_by(posteam, week) %>%
  summarise(TeamTar = sum(pass_attempt, na.rm = TRUE),
            TeamRec = sum(complete_pass, na.rm = TRUE),
            TeamAYs = sum(abs_air_yards, na.rm = TRUE),
            TeamRecYD = sum(yards_gained, na.rm = TRUE),
            TeamRec1D = sum(first_down_pass, na.rm = TRUE),
            TeamRecTD = sum(pass_touchdown, na.rm = TRUE),
            eTeamRecFP = sum(eRecFP, na.rm = TRUE),
            TeamRecFP = sum(RecFP, na.rm = TRUE),
            eTeamRecFP1D = sum(eRecFP1D, na.rm= TRUE),
            TeamRecFP1D = sum(RecFP1D, na.rm = TRUE)
  ) %>%
  ungroup()

weeklyRecDF <- recdf %>%
  group_by(receiver_player_id, posteam, week) %>%
  summarise(Tar = sum(pass_attempt, na.rm = TRUE),
            Rec = sum(complete_pass, na.rm = TRUE),
            AYs = sum(abs_air_yards, na.rm=TRUE),
            RecYD = sum(yards_gained, na.rm = TRUE),
            Rec1D = sum(first_down_pass, na.rm = TRUE),
            RecTD = sum(pass_touchdown, na.rm = TRUE),
            eRecYD = sum(eRecYD, na.rm = TRUE),
            eTDRec = sum(eRecTD, na.rm = TRUE),
            eRec1D = sum(eRec1D, na.rm = TRUE),
            eRecFP = sum(eRecFP, na.rm = TRUE),
            RecFP = sum(RecFP, na.rm = TRUE),
            RecDiff = (RecFP - eRecFP),            
            eRecFP1D = sum(eRecFP1D, na.rm= TRUE),
            RecFP1D = sum(RecFP1D, na.rm = TRUE),
            RecDiff1D = (RecFP1D - eRecFP1D),
            RecGames = n_distinct(game_id)) %>%
  ungroup()


dfnewmerged <- full_join(weeklyRushDF, weeklyRecDF, by = c("rusher_player_id" = "receiver_player_id", "posteam" = "posteam", "week"="week")) %>%
  #inner_join(select(database, gsis_id, mergename, pos), by = c("rusher_player_id" = "gsis_id")) %>%
  inner_join(weeklyTeamRushDF, by = c("posteam"="posteam", "week"="week")) %>%
  inner_join(weeklyTeamRecDF, by = c("posteam"="posteam", "week"="week")) %>%
  mutate(
    eTD = eTDRec + eTDRush,
    eYD = eRecYD + eRushYD,
    e1D = eRec1D + eRush1D,
    eFP = eRecFP + eRushFP,
    FP = RecFP + RushFP,
    Diff = FP - eFP,
    eFP1D = eRecFP1D + eRushFP1D,
    FP1D = RecFP1D + RushFP1D,
    Diff1D = FP1D - eFP1D,
    eTeamFP = eTeamRecFP + eTeamRushFP,
    TeamFP = TeamRecFP + TeamRushFP,
    TeamDiff = TeamFP - eTeamFP,
    eTeamFP1D = eTeamRecFP1D + eTeamRushFP1D,
    TeamFP1D = TeamRecFP1D + TeamRushFP1D,
    TeamDiff1D = TeamFP1D - eTeamFP1D,     
    Games = max(RushGames, RecGames, na.rm = TRUE)
  ) 