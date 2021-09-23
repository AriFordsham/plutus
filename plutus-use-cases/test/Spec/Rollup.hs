{-# LANGUAGE ExplicitForAll   #-}
{-# LANGUAGE FlexibleContexts #-}

module Spec.Rollup where

import qualified Control.Foldl                 as L
import           Control.Monad.Freer           (run)
import           Data.ByteString.Lazy          (ByteString)
import qualified Data.ByteString.Lazy          as LBS
import           Data.Default                  (Default (..))
import           Data.Text.Encoding            (encodeUtf8)

import           Plutus.Contract.Trace

import           Plutus.Contracts.Crowdfunding
import qualified Spec.GameStateMachine
import qualified Spec.Vesting

import           Plutus.Trace.Emulator         (EmulatorTrace, runEmulatorStream)
import qualified Streaming.Prelude             as S
import           Test.Tasty                    (TestTree, testGroup)
import           Test.Tasty.Golden             (goldenVsString)
import           Test.Tasty.HUnit              (assertFailure)
import           Wallet.Emulator.Stream        (foldEmulatorStreamM, takeUntilSlot)
import           Wallet.Rollup.Render          (showBlockchainFold)

tests :: TestTree
tests = testGroup "showBlockchain"
     [ goldenVsString
          "renders a crowdfunding scenario sensibly"
          "test/Spec/renderCrowdfunding.txt"
          (render successfulCampaign)
     , goldenVsString
          "renders a game guess scenario sensibly"
          "test/Spec/renderGuess.txt"
          (render Spec.GameStateMachine.successTrace)
     , goldenVsString
          "renders a vesting scenario sensibly"
          "test/Spec/renderVesting.txt"
          (render Spec.Vesting.retrieveFundsTrace)
     ]

render :: forall a. EmulatorTrace a -> IO ByteString
render trace = do
    let result =
               S.fst'
               $ run
               $ foldEmulatorStreamM (L.generalize (showBlockchainFold knownWallets'))
               $ takeUntilSlot 21
               $ runEmulatorStream def trace
        knownWallets' = fmap (\w -> (walletPubKeyHash w, w)) knownWallets
    case result of
        Left err       -> assertFailure $ show err
        Right rendered -> pure $ LBS.fromStrict $ encodeUtf8 rendered
