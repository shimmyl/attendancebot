{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ViewPatterns #-}

module Main where

import Attendance.Monad
import Attendance.Report
import Attendance.Schedule
import Control.Lens
import Control.Monad.Except
import Data.Maybe
import qualified Data.Text as T
import Data.Thyme
import Data.Thyme.Clock.POSIX
import Data.Thyme.Time
import Data.Time.Zones
import Data.Time.Zones.All
import System.Environment
import Web.Slack hiding (lines)

-------------------------------------------------------------------------------

main :: IO ()
main = do
    slackConfig <- getSlackConfig
    logPath <- getCheckinLog
    withAttnH slackConfig logPath blacklist timezone deadline $ \h -> do
        -- start cron thread
        runJobs (runAttendance h . snd) scheduledJobs
        -- run main loop
        runAttendance h $ forever (getNextEvent >>= handleEvent)

handleEvent :: Event -> Attendance ()
handleEvent ev = case ev of
    ReactionAdded uid _ item_uid _ ts | item_uid == user_me ->
        checkin uid (timestampToUTCTime ts)
    Message cid (UserComment uid) msg (timestampToUTCTime -> ts) _ _ -> do
        isIM <- channelIsIM cid
        when (isIM && uid /= user_me) $ case msg of
            "active" -> markActive uid ts
            "inactive" -> markInactive uid ts
            "debug" -> dumpDebug uid scheduledJobs
            "summary" -> sendRichIM uid "" . (:[]) =<< weeklySummary
            _ -> checkin uid ts
    ImCreated _ im -> trackUser im
    _ -> liftIO $ print ev

-------------------------------------------------------------------------------
-- Configuration

getSlackConfig :: IO SlackConfig
getSlackConfig =
    maybe (error "SLACK_API_TOKEN not set") SlackConfig <$> lookupEnv "SLACK_API_TOKEN"

getCheckinLog :: IO FilePath
getCheckinLog =
    fromMaybe (error "ATTENDANCE_LOG not set") <$> lookupEnv "ATTENDANCE_LOG"

-- | Users which we want to ignore
blacklist :: [UserId]
blacklist =
    [ Id "USLACKBOT" -- @slackbot
    ]

timezone :: TZ
timezone = tzByLabel Asia__Tokyo

deadline :: TimeOfDay
deadline = TimeOfDay 9 0 (fromSeconds' 0)  -- 9am JST

-- TODO: Get this from session
user_me :: UserId
user_me = Id ""  -- @attendancebot

channel_announce :: ChannelId
channel_announce = Id ""

-------------------------------------------------------------------------------

scheduledJobs :: [CronJob (T.Text, Attendance ())]
scheduledJobs =
    [ mkJob "45 23 * * 0-4" ("remind missing"      , remindMissing      )  -- 8:45 mon-fri
    , mkJob "55 23 * * 0-4" ("send daily summary"  , sendDailySummary   )  -- 8:55 mon-fri
    , mkJob "31 3 * * 5"    ("send weekly summary" , sendWeeklySummary  )  -- midday on friday
    , mkJob "00 20 * * 0-4" ("download spreadsheet", downloadSpreadsheet)  -- 5:00 mon-fri
    ]

sendDailySummary :: Attendance ()
sendDailySummary = sendMessage channel_announce =<< dailySummary

remindMissing :: Attendance ()
remindMissing = mapM_ (uncurry sendIM) =<< missingReport

sendWeeklySummary :: Attendance ()
sendWeeklySummary = do
    attachment <- weeklySummary
    ret <- sendRichMessage channel_announce "" [attachment]
    either (liftIO . putStrLn . T.unpack) return ret

-------------------------------------------------------------------------------
-- Helpers

timestampToUTCTime :: SlackTimeStamp -> UTCTime
timestampToUTCTime = view (slackTime . getTime . thyme . from posixTime)
