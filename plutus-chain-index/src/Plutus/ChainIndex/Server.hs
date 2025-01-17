{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MonoLocalBinds   #-}
{-# LANGUAGE RankNTypes       #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators    #-}
module Plutus.ChainIndex.Server(
    serveChainIndexQueryServer,
    serveChainIndex) where

import           Cardano.BM.Trace                  (Trace)
import           Control.Concurrent.STM            (TVar)
import qualified Control.Concurrent.STM            as STM
import           Control.Monad                     ((>=>))
import qualified Control.Monad.Except              as E
import           Control.Monad.Freer               (Eff, Member, interpret, runM, type (~>))
import           Control.Monad.Freer.Error         (Error, handleError, runError, throwError)
import           Control.Monad.Freer.Extras.Beam   (handleBeam)
import           Control.Monad.Freer.Extras.Log    (handleLogIgnore)
import           Control.Monad.Freer.Extras.Modify (raiseEnd)
import           Control.Monad.Freer.Reader        (runReader)
import           Control.Monad.Freer.State         (evalState)
import           Control.Monad.IO.Class            (MonadIO (liftIO))
import qualified Data.ByteString.Lazy              as BSL
import           Data.Default                      (Default (def))
import           Data.Maybe                        (fromMaybe)
import           Data.Proxy                        (Proxy (..))
import qualified Data.Text                         as Text
import qualified Data.Text.Encoding                as Text
import qualified Database.SQLite.Simple            as Sqlite
import qualified Network.Wai.Handler.Warp          as Warp
import           Plutus.ChainIndex.Api             (API, FromHashAPI, UtxoAtAddressRequest (UtxoAtAddressRequest))
import           Plutus.ChainIndex.ChainIndexError (ChainIndexError (..))
import           Plutus.ChainIndex.ChainIndexLog   (ChainIndexLog (..))
import           Plutus.ChainIndex.Effects         (ChainIndexControlEffect, ChainIndexQueryEffect)
import qualified Plutus.ChainIndex.Effects         as E
import           Plutus.ChainIndex.Handlers        (ChainIndexState, handleControl, handleQuery)
import           Plutus.Monitoring.Util            (convertLog)
import           Servant.API                       ((:<|>) (..))
import           Servant.API.ContentTypes          (NoContent (..))
import           Servant.Server                    (Handler, ServerError, ServerT, err404, err500, errBody, hoistServer,
                                                    serve)
serveChainIndexQueryServer ::
    Int -- ^ Port
    -> Trace IO ChainIndexLog
    -> TVar ChainIndexState -- ^ Chain index state
    -> Sqlite.Connection -- ^ Sqlite DB connection
    -> IO ()
serveChainIndexQueryServer port trace diskState conn = do
    let server = hoistServer (Proxy @API) (runChainIndexQuery trace diskState conn) serveChainIndex
    Warp.run port (serve (Proxy @API) server)

runChainIndexQuery ::
    Trace IO ChainIndexLog
    -> TVar ChainIndexState
    -> Sqlite.Connection
    -> Eff '[ChainIndexQueryEffect, ChainIndexControlEffect, Error ServerError] ~> Handler
runChainIndexQuery trace emState_ conn action = do
    emState <- liftIO (STM.readTVarIO emState_)
    result <- liftIO $ runM
                    $ evalState emState
                    $ runError @ChainIndexError
                    $ flip handleError (throwError . BeamEffectError)
                    $ handleLogIgnore @ChainIndexLog
                    $ runReader conn
                    $ interpret (handleBeam (convertLog BeamLogItem trace))
                    $ runError
                    $ interpret handleControl
                    $ interpret handleQuery
                    $ raiseEnd action
    case result of
        Right (Right a) -> pure a
        Right (Left e) -> E.throwError e
        Left e' ->
            let err = err500 { errBody = BSL.fromStrict $ Text.encodeUtf8 $ Text.pack $ show e' } in
            E.throwError err

serveChainIndex ::
    forall effs.
    ( Member (Error ServerError) effs
    , Member ChainIndexQueryEffect effs
    , Member ChainIndexControlEffect effs
    )
    => ServerT API (Eff effs)
serveChainIndex =
    pure NoContent
    :<|> serveFromHashApi
    :<|> (E.txOutFromRef >=> handleMaybe)
    :<|> (E.txFromTxId >=> handleMaybe)
    :<|> E.utxoSetMembership
    :<|> (\(UtxoAtAddressRequest pq c) -> E.utxoSetAtAddress (fromMaybe def pq) c)
    :<|> E.getTip
    :<|> E.collectGarbage *> pure NoContent
    :<|> E.getDiagnostics

serveFromHashApi ::
    forall effs.
    ( Member (Error ServerError) effs
    , Member ChainIndexQueryEffect effs
    )
    => ServerT FromHashAPI (Eff effs)
serveFromHashApi =
    (E.datumFromHash >=> handleMaybe)
    :<|> (E.validatorFromHash >=> handleMaybe)
    :<|> (E.mintingPolicyFromHash >=> handleMaybe)
    :<|> (E.stakeValidatorFromHash >=> handleMaybe)
    :<|> (E.redeemerFromHash >=> handleMaybe)

-- | Return the value of throw a 404 error
handleMaybe :: forall effs. Member (Error ServerError) effs => Maybe ~> Eff effs
handleMaybe = maybe (throwError err404) pure
