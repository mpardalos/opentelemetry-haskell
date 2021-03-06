{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module OpenTelemetry.EventlogStreaming_Internal where

import Control.Concurrent (threadDelay)
import qualified Data.Binary.Get as DBG
import Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as LBS
import qualified Data.HashMap.Strict as HM
import qualified Data.IntMap as IM
import Data.List (isSuffixOf)
import Data.Maybe
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word
import GHC.Generics
import GHC.RTS.Events
import GHC.RTS.Events.Incremental
import GHC.Stack
import OpenTelemetry.Common hiding (Event, Timestamp)
import OpenTelemetry.Debug
import OpenTelemetry.SpanContext
import OpenTelemetry.Metrics
import Text.Printf
import Text.Read
import qualified System.Random.SplitMix as R

import OpenTelemetry.Eventlog_Internal
import System.Clock
import System.IO

data WatDoOnEOF = StopOnEOF | SleepAndRetryOnEOF

data State = S
  { originTimestamp :: !Timestamp,
    threadMap :: IM.IntMap ThreadId,
    spans :: HM.HashMap SpanId Span,
    traceMap :: HM.HashMap ThreadId TraceId,
    serial2sid :: HM.HashMap Word64 SpanId,
    thread2sid :: HM.HashMap ThreadId SpanId,
    gcStartedAt :: !Timestamp,
    gcGeneration :: !Int,
    counterEventsProcessed :: !Int,
    counterOpenTelemetryEventsProcessed :: !Int,
    counterSpansEmitted :: !Int,
    randomGen :: R.SMGen
  }
  deriving (Show)

initialState :: Word64 -> R.SMGen -> State
initialState timestamp = S timestamp mempty mempty mempty mempty mempty 0 0 0 0 0

data EventSource
  = EventLogHandle Handle WatDoOnEOF
  | EventLogFilename FilePath

work :: Timestamp -> Exporter Span -> Exporter Metric -> EventSource -> IO ()
work origin_timestamp span_exporter metric_exporter source = do
  d_ "Starting the eventlog reader"
  smgen <- R.initSMGen -- TODO(divanov): seed the random generator with something more random than current time
  let state0 = initialState origin_timestamp smgen
  case source of
    EventLogFilename path -> do
      readEventLogFromFile path >>= \case
        Right (dat -> Data {events}) -> do
          let go _ [] = pure ()
              go s (e : es) = do
                dd_ "event" (evTime e, evCap e, evSpec e)
                case processEvent e s of
                  (s', sps, ms) -> do
                    case sps of
                      [] -> pure ()
                      _ -> do
                        mapM_ (d_ . ("emit span " <>) . show) sps
                        _ <- export span_exporter sps
                        pure ()
                    case ms of
                      [] -> pure ()
                      _ -> do
                        mapM_ (d_ . ("emit metric " <>) . show) ms
                        _ <- export metric_exporter ms
                        pure ()
                    go s' es
          go state0 $ sortEvents events
        Left err -> do
          putStrLn err
    EventLogHandle input wat_do_on_eof -> do
      let go s (Produce event next) = do
            case evSpec event of
              Shutdown {} -> do
                d_ "Shutdown-like event detected"
              CapDelete {} -> do
                d_ "Shutdown-like event detected"
              CapsetDelete {} -> do
                d_ "Shutdown-like event detected"
              _ -> do
                -- d_ "go Produce"
                dd_ "event" (evTime event, evCap event, evSpec event)
                let (s', sps, _ms) = processEvent event s
                _ <- export span_exporter sps
                -- print s'
                mapM_ (d_ . ("emit " <>) . show) sps
                go s' next
          go s d@(Consume consume) = do
            -- d_ "go Consume"
            eof <- hIsEOF input
            case eof of
              False -> do
                chunk <- B.hGetSome input 4096
                -- printf "chunk = %d bytes\n" (B.length chunk)
                if B.null chunk
                  then do
                    -- d_ "chunk is null"
                    threadDelay 1000 -- TODO(divanov): remove the sleep by replacing the hGetSome with something that blocks until data is available
                    go s d
                  else do
                    -- d_ "chunk is not null"
                    go s $ consume chunk
              True -> do
                d_ "EOF"
                case wat_do_on_eof of
                  StopOnEOF -> pure ()
                  SleepAndRetryOnEOF -> do
                    threadDelay 1000
                    go s d
          go _ (Done _) = do
            d_ "go Done"
            pure ()
          go _ (Error _leftover err) = do
            d_ "go Error"
            d_ err
      go state0 decodeEventLog
  d_ "no more work"

parseOpenTelemetry :: EventInfo -> Maybe OpenTelemetryEventlogEvent
parseOpenTelemetry UserMessage {msg} = parseText (T.words msg)
parseOpenTelemetry UserBinaryMessage {payload} = parseByteString payload
parseOpenTelemetry _ = Nothing

processEvent :: Event -> State -> (State, [Span], [Metric])
processEvent (Event ts ev m_cap) st@(S {..}) =
  let now = originTimestamp + ts
      m_thread_id = m_cap >>= flip IM.lookup threadMap
      m_trace_id = m_thread_id >>= flip HM.lookup traceMap
   in case (ev, m_cap, m_thread_id) of
        (WallClockTime {sec, nsec}, _, _) ->
          (st {originTimestamp = sec * 1_000_000_000 + fromIntegral nsec - ts}, [], [])
        (CreateThread new_tid, _, _) ->
          let trace_id = case m_trace_id of
                Just t -> t
                Nothing -> TId originTimestamp -- TODO: something more random
           in (st { traceMap = HM.insert new_tid trace_id traceMap }
              , []
              , [Metric (SomeInstrument threadsI) [MetricDatapoint now 1]])
        (RunThread tid, Just cap, _) ->
          (st {threadMap = IM.insert cap tid threadMap}, [], [])
        (StopThread tid tstatus, Just cap, _)
          | isTerminalThreadStatus tstatus ->
            ( st
                { threadMap = IM.delete cap threadMap
                , traceMap = HM.delete tid traceMap
                },
              []
            , [Metric (SomeInstrument threadsI) [MetricDatapoint now (-1)]])
        (StartGC, _, _) ->
          (st {gcStartedAt = now}, [], [])
        (HeapLive {liveBytes}, _, _) -> (st, [], [Metric (SomeInstrument heapLiveBytesI) [MetricDatapoint now $ fromIntegral liveBytes]])
        (HeapAllocated {allocBytes}, (Just cap), _) ->
          (st, [], [Metric (SomeInstrument $ heapAllocBytesI cap) [MetricDatapoint now $ fromIntegral allocBytes]])
        (EndGC, _, _) ->
          let (span_id, randomGen') = R.nextWord64 randomGen
              sp =
                Span
                  { spanOperation = "gc",
                    spanContext = SpanContext (SId span_id) (TId span_id),
                    spanStartedAt = gcStartedAt,
                    spanFinishedAt = now,
                    spanThreadId = maxBound,
                    spanTags = mempty,
                    spanEvents = mempty,
                    spanParentId = Nothing,
                    spanStatus = OK,
                    spanNanosecondsSpentInGC = now - gcStartedAt
                  }
              spans' = fmap (\live_span -> live_span {spanNanosecondsSpentInGC = (now - gcStartedAt) + spanNanosecondsSpentInGC live_span}) spans
              st' = st {randomGen = randomGen', spans = spans'}
           in (st', [sp], [Metric (SomeInstrument gcTimeI) [MetricDatapoint now (fromIntegral $ now - gcStartedAt)]])
        (parseOpenTelemetry -> Just ev', _, fromMaybe 1 -> tid) ->
          handleOpenTelemetryEventlogEvent ev' st (tid, now, m_trace_id)
        _ -> (st, [], [])
  where
    threadsI :: UpDownSumObserver
    threadsI = UpDownSumObserver "threads"

    heapLiveBytesI :: ValueObserver
    heapLiveBytesI = ValueObserver "heap_live_bytes"

    gcTimeI :: SumObserver
    gcTimeI = SumObserver "gc"

    heapAllocBytesI :: Int -> SumObserver
    heapAllocBytesI cap = SumObserver ("cap_" <> B8.pack (show cap) <> "_heap_alloc_bytes")


isTerminalThreadStatus :: ThreadStopStatus -> Bool
isTerminalThreadStatus ThreadFinished = True
isTerminalThreadStatus _ = False

data OpenTelemetryEventlogEvent
  = BeginSpanEv SpanInFlight SpanName
  | EndSpanEv SpanInFlight
  | TagEv SpanInFlight TagName TagVal
  | EventEv SpanInFlight EventName EventVal
  | SetParentEv SpanInFlight SpanContext
  | SetTraceEv SpanInFlight TraceId
  | SetSpanEv SpanInFlight SpanId
  | MetricEv    SomeInstrument Int
  deriving (Show, Eq, Generic)

handleOpenTelemetryEventlogEvent ::
  OpenTelemetryEventlogEvent ->
  State ->
  (Word32, Timestamp, Maybe TraceId) ->
  (State, [Span], [Metric])
handleOpenTelemetryEventlogEvent m st (tid, now, m_trace_id) =
  case m of
    EventEv (SpanInFlight serial) k v ->
      case HM.lookup serial (serial2sid st) of
        Just span_id -> (modifySpan span_id (addEvent now k v) st, [], [])
        Nothing -> error $ "add event: span not found for serial " <> show serial
    SetParentEv (SpanInFlight serial) (SpanContext psid trace_id) ->
      case HM.lookup serial $ serial2sid st of
        Just span_id ->
          ( (modifySpan span_id (setParent trace_id psid) st)
              { traceMap = HM.insert tid trace_id (traceMap st)
              },
            [],
            []
          )
        Nothing -> error $ "set parent: span not found for serial " <> show serial
    SetSpanEv (SpanInFlight serial) span_id ->
      case HM.lookup serial $ serial2sid st of
        Just old_span_id -> (modifySpan old_span_id (setSpanId span_id) st, [], [])
        Nothing -> error $ "set spanid " <> show serial <> " " <> show span_id <> ": span id not found"
    SetTraceEv (SpanInFlight serial) trace_id ->
      case HM.lookup serial $ serial2sid st of
        Nothing -> error $ "set traceid: span id not found for serial" <> show serial
        Just span_id ->
          ( (modifySpan span_id (setTraceId trace_id) st)
              { traceMap = HM.insert tid trace_id $ traceMap st
              },
            [],
            []
          )
    TagEv (SpanInFlight serial) k v ->
      case HM.lookup serial $ serial2sid st of
        Nothing -> error $ "set tag: span id not found for serial" <> show serial
        Just span_id -> (modifySpan span_id (setTag k v) st, [], [])
    EndSpanEv (SpanInFlight serial) ->
      case HM.lookup serial $ serial2sid st of
        Nothing ->
          let (st', span_id) = inventSpanId serial st
              parent = HM.lookup tid (thread2sid st)
              sp =
                Span
                  { spanContext = SpanContext span_id (fromMaybe (TId 42) m_trace_id),
                    spanOperation = "",
                    spanThreadId = tid,
                    spanStartedAt = 0,
                    spanFinishedAt = now,
                    spanTags = mempty,
                    spanEvents = mempty,
                    spanStatus = OK,
                    spanNanosecondsSpentInGC = 0,
                    spanParentId = parent
                  }
           in (createSpan span_id sp st', [], [])
        Just span_id ->
          let (st', sp) = emitSpan serial span_id st
           in (st', [sp {spanFinishedAt = now}], [])
    BeginSpanEv (SpanInFlight serial) (SpanName operation) ->
      case HM.lookup serial (serial2sid st) of
        Nothing ->
          let (st', span_id) = inventSpanId serial st
              parent = HM.lookup tid (thread2sid st)
              sp =
                Span
                  { spanContext = SpanContext span_id (fromMaybe (TId 42) m_trace_id),
                    spanOperation = operation,
                    spanThreadId = tid,
                    spanStartedAt = now,
                    spanFinishedAt = 0,
                    spanTags = mempty,
                    spanEvents = mempty,
                    spanStatus = OK,
                    spanNanosecondsSpentInGC = 0,
                    spanParentId = parent
                  }
           in (createSpan span_id sp st', [], [])
        Just span_id ->
          let (st', sp) = emitSpan serial span_id st
           in (st', [sp {spanOperation = operation, spanStartedAt = now, spanThreadId = tid}], [])
    MetricEv instrument val -> (st, [], [Metric instrument [MetricDatapoint now val]])

createSpan :: SpanId -> Span -> State -> State
createSpan span_id sp st =
  st
    { spans = HM.insert span_id sp (spans st),
      thread2sid = HM.insert (spanThreadId sp) span_id (thread2sid st)
    }

emitSpan :: Word64 -> SpanId -> State -> (State, Span)
emitSpan serial span_id st =
  case (HM.lookup serial $ serial2sid st, HM.lookup span_id $ spans st) of
    (Just span_id', Just sp)
      | span_id == span_id' ->
        ( st
            { spans = HM.delete span_id $ spans st,
              serial2sid = HM.delete serial $ serial2sid st,
              thread2sid =
                HM.update
                  (const $ spanParentId sp)
                  (spanThreadId sp)
                  (thread2sid st)
            },
          sp
        )
    _ -> error "emitSpan invariants violated"

modifySpan :: HasCallStack => SpanId -> (Span -> Span) -> State -> State
modifySpan sid f st = st {spans = HM.adjust f sid (spans st)}

setParent :: TraceId -> SpanId -> Span -> Span
setParent ptid psid sp =
  sp
    { spanParentId = Just psid,
      spanContext = SpanContext (spanId sp) ptid
    }

addEvent :: Timestamp -> EventName -> EventVal -> Span -> Span
addEvent ts k v sp = sp {spanEvents = new_events}
  where
    new_events = ev : spanEvents sp
    ev = SpanEvent ts k v

setTraceId :: TraceId -> Span -> Span
setTraceId tid sp =
  sp
    { spanContext = SpanContext (spanId sp) tid
    }

setTag :: ToTagValue v => TagName -> v -> Span -> Span
setTag k v sp =
  sp
    { spanTags = HM.insert k (toTagValue v) (spanTags sp)
    }

setSpanId :: SpanId -> Span -> Span
setSpanId sid sp =
  sp
    { spanContext = SpanContext sid (spanTraceId sp)
    }

inventSpanId :: Word64 -> State -> (State, SpanId)
inventSpanId serial st = (st', sid)
  where
    S {serial2sid, randomGen} = st
    (SId -> sid, randomGen') = R.nextWord64 randomGen
    st' = st {serial2sid = HM.insert serial sid serial2sid, randomGen = randomGen'}

parseText :: [T.Text] -> Maybe OpenTelemetryEventlogEvent
parseText =
    \case
      ("ot2" : "begin" : "span" : serial_text : name) ->
        let serial = read (T.unpack serial_text)
            operation = T.intercalate " " name
         in Just $ BeginSpanEv (SpanInFlight serial) (SpanName operation)
      ["ot2", "end", "span", serial_text] ->
        let serial = read (T.unpack serial_text)
         in Just $ EndSpanEv (SpanInFlight serial)
      ("ot2" : "set" : "tag" : serial_text : k : v) ->
        let serial = read (T.unpack serial_text)
         in Just $ TagEv (SpanInFlight serial) (TagName k) (TagVal $ T.unwords v)
      ["ot2", "set", "traceid", serial_text, trace_id_text] ->
        let serial = read (T.unpack serial_text)
            trace_id = TId (read ("0x" <> T.unpack trace_id_text))
         in Just $ SetTraceEv (SpanInFlight serial) trace_id
      ["ot2", "set", "spanid", serial_text, new_span_id_text] ->
        let serial = read (T.unpack serial_text)
            span_id = (SId (read ("0x" <> T.unpack new_span_id_text)))
         in Just $ SetSpanEv (SpanInFlight serial) span_id
      ["ot2", "set", "parent", serial_text, trace_id_text, parent_span_id_text] ->
        let trace_id = TId (read ("0x" <> T.unpack trace_id_text))
            serial = read (T.unpack serial_text)
            psid = SId (read ("0x" <> T.unpack parent_span_id_text))
         in Just $
              SetParentEv
                (SpanInFlight serial)
                (SpanContext psid trace_id)
      ("ot2" : "add" : "event" : serial_text : k : v) ->
        let serial = read (T.unpack serial_text)
         in Just . EventEv (SpanInFlight serial) (EventName k) $ EventVal $ T.unwords v
      ("ot2" : "metric" : instrumentTypeStr : name : valStr) ->
        let mInstrumentType = readInstrumentTagStr $ T.unpack instrumentTypeStr
            mVal = readMaybe (T.unpack $ T.unwords valStr)
         in case (mInstrumentType, mVal) of
            (Just instrumentType, Just val) -> Just (MetricEv (instrumentType $ TE.encodeUtf8 name) val)
            (Nothing, _) -> error $ printf "Invalid instrument: %s" (show instrumentTypeStr)
            (_, Nothing) -> error $ printf "Invalid metric value: %s" (show valStr)
      ("ot2" : rest) -> error $ printf "Unrecognized %s" (show rest)
      _ -> Nothing

headerP :: DBG.Get (Maybe MsgType)
headerP = do
  h <- DBG.getWord32le
  let !msgTypeId = shiftR h 24
  if otelMagic == fromIntegral h .&. otelMagic
    then
      if msgTypeId > 7 && msgTypeId < 1
        then fail $ "Bad Msg Type: " ++ show msgTypeId
        else return . Just . MsgType . fromIntegral $ msgTypeId
    else return Nothing

lastStringP :: DBG.Get T.Text
lastStringP = (TE.decodeUtf8 . LBS.toStrict) <$> DBG.getRemainingLazyByteString

stringP :: Word32 -> DBG.Get T.Text
stringP len = TE.decodeUtf8 <$> DBG.getByteString (fromIntegral len)

logEventBodyP :: MsgType -> DBG.Get OpenTelemetryEventlogEvent
logEventBodyP msgType =
  case msgType of
    BEGIN_SPAN ->
      BeginSpanEv <$> (SpanInFlight <$> DBG.getWord64le)
        <*> (SpanName <$> lastStringP)
    END_SPAN -> EndSpanEv <$> (SpanInFlight <$> DBG.getWord64le)
    TAG -> do
      sp <- SpanInFlight <$> DBG.getWord64le
      klen <- DBG.getWord32le
      vlen <- DBG.getWord32le
      k <- TagName <$> stringP klen
      v <- TagVal <$> stringP vlen
      pure $ TagEv sp k v
    EVENT -> do
      sp <- SpanInFlight <$> DBG.getWord64le
      klen <- DBG.getWord32le
      vlen <- DBG.getWord32le
      k <- EventName <$> stringP klen
      v <- EventVal <$> stringP vlen
      pure $ EventEv sp k v
    SET_PARENT_CONTEXT ->
      SetParentEv <$> (SpanInFlight <$> DBG.getWord64le)
        <*> (SpanContext <$> (SId <$> DBG.getWord64le) <*> (TId <$> DBG.getWord64le))
    SET_TRACE_ID ->
      SetTraceEv <$> (SpanInFlight <$> DBG.getWord64le)
        <*> (TId <$> DBG.getWord64le)
    SET_SPAN_ID ->
      SetSpanEv <$> (SpanInFlight <$> DBG.getWord64le)
        <*> (SId <$> DBG.getWord64le)
    METRIC_CAPTURE -> do
      iTag <- DBG.getInt8
      val <- fromIntegral <$> DBG.getInt64le
      iName <- LBS.toStrict <$> DBG.getRemainingLazyByteString
      case readInstrumentTag iTag of
        Just iType -> return $ MetricEv (iType iName) val
        Nothing -> fail $ "Invalid instrument tag: " ++ show iTag
    MsgType mti ->
      fail $ "Log event of type " ++ show mti ++ " is not supported"

logEventP :: DBG.Get (Maybe OpenTelemetryEventlogEvent)
logEventP =
  DBG.lookAheadM headerP >>= \case
    Nothing -> return Nothing
    Just msgType -> logEventBodyP msgType >>= return . Just

parseByteString :: B.ByteString -> Maybe OpenTelemetryEventlogEvent
parseByteString = DBG.runGet logEventP . LBS.fromStrict

exportEventlog :: Exporter Span -> Exporter Metric -> FilePath -> IO ()
exportEventlog span_exporter metric_exporter path = do
  origin_timestamp <- fromIntegral . toNanoSecs <$> getTime Realtime
  -- TODO(divanov): better way of understanding whether filename points to a named pipe
  case ".pipe" `isSuffixOf` path of
    True -> do
      withFile
        path
        ReadMode
        ( \handle ->
            work origin_timestamp span_exporter metric_exporter $ EventLogHandle handle SleepAndRetryOnEOF
        )
    False -> work origin_timestamp span_exporter metric_exporter $ EventLogFilename path
