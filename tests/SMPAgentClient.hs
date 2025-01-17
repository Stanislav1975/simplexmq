{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module SMPAgentClient where

import Control.Monad.IO.Unlift
import Crypto.Random
import qualified Data.ByteString.Char8 as B
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as L
import Network.Socket (ServiceName)
import NtfClient (ntfTestPort)
import SMPClient
  ( serverBracket,
    testKeyHash,
    testPort,
    testPort2,
    withSmpServer,
    withSmpServerOn,
    withSmpServerThreadOn,
  )
import Simplex.Messaging.Agent.Env.SQLite
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.RetryInterval
import Simplex.Messaging.Agent.Server (runSMPAgentBlocking)
import Simplex.Messaging.Client (ProtocolClientConfig (..), chooseTransportHost, defaultClientConfig, defaultNetworkConfig)
import Simplex.Messaging.Parsers (parseAll)
import Simplex.Messaging.Transport
import Simplex.Messaging.Transport.Client
import Test.Hspec
import UnliftIO.Concurrent
import UnliftIO.Directory

agentTestHost :: NonEmpty TransportHost
agentTestHost = "localhost"

agentTestPort :: ServiceName
agentTestPort = "5010"

agentTestPort2 :: ServiceName
agentTestPort2 = "5011"

agentTestPort3 :: ServiceName
agentTestPort3 = "5012"

testDB :: AgentDatabase
testDB = AgentDBFile {dbFile = "tests/tmp/smp-agent.test.protocol.db", dbKey = ""}

testDB2 :: AgentDatabase
testDB2 = AgentDBFile {dbFile = "tests/tmp/smp-agent2.test.protocol.db", dbKey = ""}

testDB3 :: AgentDatabase
testDB3 = AgentDBFile {dbFile = "tests/tmp/smp-agent3.test.protocol.db", dbKey = ""}

smpAgentTest :: forall c. Transport c => TProxy c -> ARawTransmission -> IO ARawTransmission
smpAgentTest _ cmd = runSmpAgentTest $ \(h :: c) -> tPutRaw h cmd >> get h
  where
    get h = do
      t@(_, _, cmdStr) <- tGetRaw h
      case parseAll networkCommandP cmdStr of
        Right (ACmd SAgent CONNECT {}) -> get h
        Right (ACmd SAgent DISCONNECT {}) -> get h
        _ -> pure t

runSmpAgentTest :: forall c a. Transport c => (c -> IO a) -> IO a
runSmpAgentTest test = withSmpServer t . withSmpAgent t $ testSMPAgentClient test
  where
    t = transport @c

runSmpAgentServerTest :: forall c a. Transport c => ((ThreadId, ThreadId) -> c -> IO a) -> IO a
runSmpAgentServerTest test =
  withSmpServerThreadOn t testPort $
    \server -> withSmpAgentThreadOn t (agentTestPort, testPort, testDB) $
      \agent -> testSMPAgentClient $ test (server, agent)
  where
    t = transport @c

smpAgentServerTest :: Transport c => ((ThreadId, ThreadId) -> c -> IO ()) -> Expectation
smpAgentServerTest test' = runSmpAgentServerTest test' `shouldReturn` ()

runSmpAgentTestN :: forall c a. Transport c => [(ServiceName, ServiceName, AgentDatabase)] -> ([c] -> IO a) -> IO a
runSmpAgentTestN agents test = withSmpServer t $ run agents []
  where
    run :: [(ServiceName, ServiceName, AgentDatabase)] -> [c] -> IO a
    run [] hs = test hs
    run (a@(p, _, _) : as) hs = withSmpAgentOn t a $ testSMPAgentClientOn p $ \h -> run as (h : hs)
    t = transport @c

runSmpAgentTestN_1 :: forall c a. Transport c => Int -> ([c] -> IO a) -> IO a
runSmpAgentTestN_1 nClients test = withSmpServer t . withSmpAgent t $ run nClients []
  where
    run :: Int -> [c] -> IO a
    run 0 hs = test hs
    run n hs = testSMPAgentClient $ \h -> run (n - 1) (h : hs)
    t = transport @c

smpAgentTestN :: Transport c => [(ServiceName, ServiceName, AgentDatabase)] -> ([c] -> IO ()) -> Expectation
smpAgentTestN agents test' = runSmpAgentTestN agents test' `shouldReturn` ()

smpAgentTestN_1 :: Transport c => Int -> ([c] -> IO ()) -> Expectation
smpAgentTestN_1 n test' = runSmpAgentTestN_1 n test' `shouldReturn` ()

smpAgentTest2_2_2 :: forall c. Transport c => (c -> c -> IO ()) -> Expectation
smpAgentTest2_2_2 test' =
  withSmpServerOn (transport @c) testPort2 $
    smpAgentTest2_2_2_needs_server test'

smpAgentTest2_2_2_needs_server :: forall c. Transport c => (c -> c -> IO ()) -> Expectation
smpAgentTest2_2_2_needs_server test' =
  smpAgentTestN
    [ (agentTestPort, testPort, testDB),
      (agentTestPort2, testPort2, testDB2)
    ]
    _test
  where
    _test [h1, h2] = test' h1 h2
    _test _ = error "expected 2 handles"

smpAgentTest2_2_1 :: Transport c => (c -> c -> IO ()) -> Expectation
smpAgentTest2_2_1 test' =
  smpAgentTestN
    [ (agentTestPort, testPort, testDB),
      (agentTestPort2, testPort, testDB2)
    ]
    _test
  where
    _test [h1, h2] = test' h1 h2
    _test _ = error "expected 2 handles"

smpAgentTest2_1_1 :: Transport c => (c -> c -> IO ()) -> Expectation
smpAgentTest2_1_1 test' = smpAgentTestN_1 2 _test
  where
    _test [h1, h2] = test' h1 h2
    _test _ = error "expected 2 handles"

smpAgentTest3 :: Transport c => (c -> c -> c -> IO ()) -> Expectation
smpAgentTest3 test' =
  smpAgentTestN
    [ (agentTestPort, testPort, testDB),
      (agentTestPort2, testPort, testDB2),
      (agentTestPort3, testPort, testDB3)
    ]
    _test
  where
    _test [h1, h2, h3] = test' h1 h2 h3
    _test _ = error "expected 3 handles"

smpAgentTest3_1_1 :: Transport c => (c -> c -> c -> IO ()) -> Expectation
smpAgentTest3_1_1 test' = smpAgentTestN_1 3 _test
  where
    _test [h1, h2, h3] = test' h1 h2 h3
    _test _ = error "expected 3 handles"

smpAgentTest1_1_1 :: forall c. Transport c => (c -> IO ()) -> Expectation
smpAgentTest1_1_1 test' =
  smpAgentTestN
    [(agentTestPort2, testPort2, testDB2)]
    _test
  where
    _test [h] = test' h
    _test _ = error "expected 1 handle"

testSMPServer :: SMPServer
testSMPServer = "smp://LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI=@localhost:5001"

testSMPServer2 :: SMPServer
testSMPServer2 = "smp://LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI=@localhost:5002"

initAgentServers :: InitialAgentServers
initAgentServers =
  InitialAgentServers
    { smp = L.fromList [noAuthSrv testSMPServer],
      ntf = ["ntf://LcJUMfVhwD8yxjAiSaDzzGF3-kLG4Uh0Fl_ZIjrRwjI=@localhost:6001"],
      netCfg = defaultNetworkConfig {tcpTimeout = 500_000}
    }

initAgentServers2 :: InitialAgentServers
initAgentServers2 = initAgentServers {smp = L.fromList [noAuthSrv testSMPServer, noAuthSrv testSMPServer2]}

agentCfg :: AgentConfig
agentCfg =
  defaultAgentConfig
    { tcpPort = agentTestPort,
      tbqSize = 4,
      database = testDB,
      smpCfg =
        defaultClientConfig
          { qSize = 1,
            defaultTransport = (testPort, transport @TLS),
            networkConfig = defaultNetworkConfig {tcpTimeout = 500_000}
          },
      ntfCfg =
        defaultClientConfig
          { qSize = 1,
            defaultTransport = (ntfTestPort, transport @TLS)
          },
      reconnectInterval = defaultReconnectInterval {initialInterval = 50_000},
      ntfWorkerDelay = 1000,
      ntfSMPWorkerDelay = 1000,
      caCertificateFile = "tests/fixtures/ca.crt",
      privateKeyFile = "tests/fixtures/server.key",
      certificateFile = "tests/fixtures/server.crt"
    }

withSmpAgentThreadOn_ :: (MonadUnliftIO m, MonadRandom m) => ATransport -> (ServiceName, ServiceName, AgentDatabase) -> m () -> (ThreadId -> m a) -> m a
withSmpAgentThreadOn_ t (port', smpPort', db') afterProcess =
  let cfg' = agentCfg {tcpPort = port', database = db'}
      initServers' = initAgentServers {smp = L.fromList [ProtoServerWithAuth (SMPServer "localhost" smpPort' testKeyHash) Nothing]}
   in serverBracket
        (\started -> runSMPAgentBlocking t started cfg' initServers')
        afterProcess

withSmpAgentThreadOn :: (MonadUnliftIO m, MonadRandom m) => ATransport -> (ServiceName, ServiceName, AgentDatabase) -> (ThreadId -> m a) -> m a
withSmpAgentThreadOn t a@(_, _, db') = withSmpAgentThreadOn_ t a $ removeFile (dbFile db')

withSmpAgentOn :: (MonadUnliftIO m, MonadRandom m) => ATransport -> (ServiceName, ServiceName, AgentDatabase) -> m a -> m a
withSmpAgentOn t (port', smpPort', db') = withSmpAgentThreadOn t (port', smpPort', db') . const

withSmpAgent :: (MonadUnliftIO m, MonadRandom m) => ATransport -> m a -> m a
withSmpAgent t = withSmpAgentOn t (agentTestPort, testPort, testDB)

testSMPAgentClientOn :: (Transport c, MonadUnliftIO m, MonadFail m) => ServiceName -> (c -> m a) -> m a
testSMPAgentClientOn port' client = do
  Right useHost <- pure $ chooseTransportHost defaultNetworkConfig agentTestHost
  runTransportClient defaultTransportClientConfig useHost port' (Just testKeyHash) $ \h -> do
    line <- liftIO $ getLn h
    if line == "Welcome to SMP agent v" <> B.pack simplexMQVersion
      then client h
      else do
        error $ "wrong welcome message: " <> B.unpack line

testSMPAgentClient :: (Transport c, MonadUnliftIO m, MonadFail m) => (c -> m a) -> m a
testSMPAgentClient = testSMPAgentClientOn agentTestPort
