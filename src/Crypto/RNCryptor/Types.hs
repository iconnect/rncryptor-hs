{-# LANGUAGE RecordWildCards #-}
module Crypto.RNCryptor.Types 
     ( RNCryptorHeader(..)
     , RNCryptorContext(ctxHeader, ctxKey, ctxCipher)
     , UserInput(..)
     , newRNCryptorContext
     , newRNCryptorHeader
     , makeHMAC
     , renderRNCryptorHeader
     , blockSize
     ) where

import           Control.Applicative
import           Control.Monad
import           Crypto.Cipher.AES      (AES128)
import           Crypto.Cipher.Types    (Cipher(..))
import           Crypto.Error           (CryptoFailable(..))
import           Crypto.Hash            (Digest(..))
import           Crypto.Hash.Algorithms (SHA1, SHA256)
import           Crypto.Hash.IO         (HashAlgorithm(..))
import           Crypto.KDF.PBKDF2      (generate, prfHMAC, Parameters(..))
import           Crypto.MAC.HMAC        (HMAC(..), hmac)
import           Data.ByteArray         (convert)
import           Data.ByteString        (cons, ByteString)
import qualified Data.ByteString.Char8 as C8
import           Data.Monoid
import           Data.Word
import           System.Random
import           Test.QuickCheck        (Arbitrary(..), vector)

data RNCryptorHeader = RNCryptorHeader {
        rncVersion :: !Word8
      -- ^ Data format version. Currently 3.
      , rncOptions :: !Word8
      -- ^ bit 0 - uses password
      , rncEncryptionSalt :: !ByteString
      -- ^ iff option includes "uses password"
      , rncHMACSalt :: !ByteString
      -- ^ iff options includes "uses password"
      , rncIV :: !ByteString
      -- ^ The initialisation vector
      -- The ciphertext is variable and encrypted in CBC mode
      , rncHMAC :: (ByteString -> ByteString -> ByteString)
      -- ^ Function to compute the HMAC (32 bytes),
      -- args are user key and message bytes
      }

instance Show RNCryptorHeader where
  show = C8.unpack . renderRNCryptorHeader

instance Arbitrary RNCryptorHeader where
  arbitrary = do
    let version = toEnum 3
    let options = toEnum 1
    eSalt    <- C8.pack <$> vector saltSize
    iv       <- C8.pack <$> vector blockSize
    hmacSalt <- C8.pack <$> vector saltSize
    return RNCryptorHeader {
          rncVersion = version
        , rncOptions = options
        , rncEncryptionSalt = eSalt
        , rncHMACSalt = hmacSalt
        , rncIV = iv
        , rncHMAC = makeHMAC hmacSalt
        }

--------------------------------------------------------------------------------
saltSize :: Int
saltSize = 8

--------------------------------------------------------------------------------
blockSize :: Int
blockSize = 16

--------------------------------------------------------------------------------
randomSaltIO :: Int -> IO ByteString
randomSaltIO sz = C8.pack <$> forM [1 .. sz] (const $ randomRIO ('\NUL', '\255'))

--------------------------------------------------------------------------------
makeHMAC :: ByteString -> ByteString -> ByteString -> ByteString
makeHMAC hmacSalt userKey secret =
  let key        = generate (prfHMAC (undefined::SHA1)) (Parameters 10000 32) userKey hmacSalt::ByteString
      hmacSha256 = hmac key secret::HMAC SHA256
  in
      convert hmacSha256

--------------------------------------------------------------------------------
-- | Generates a new 'RNCryptorHeader', suitable for encryption.
newRNCryptorHeader :: IO RNCryptorHeader
newRNCryptorHeader = do
  let version = toEnum 3
  let options = toEnum 1
  eSalt    <- randomSaltIO saltSize
  iv       <- randomSaltIO blockSize
  hmacSalt <- randomSaltIO saltSize
  return RNCryptorHeader {
        rncVersion = version
      , rncOptions = options
      , rncEncryptionSalt = eSalt
      , rncHMACSalt = hmacSalt
      , rncIV = iv
      , rncHMAC = makeHMAC hmacSalt
      }

--------------------------------------------------------------------------------
-- | Concatenates this 'RNCryptorHeader' into a raw sequence of bytes, up to the
-- IV. This means you need to append the ciphertext plus the HMAC to finalise 
-- the encrypted file.
renderRNCryptorHeader :: RNCryptorHeader -> ByteString
renderRNCryptorHeader RNCryptorHeader{..} =
  rncVersion `cons` rncOptions `cons` (rncEncryptionSalt <> rncHMACSalt <> rncIV)

--------------------------------------------------------------------------------
-- A convenient datatype to avoid carrying around the AES cypher,
-- the encrypted key and so on and so forth.
data RNCryptorContext = RNCryptorContext {
        ctxHeader :: RNCryptorHeader
      , ctxKey    :: ByteString
      , ctxCipher :: AES128
      }

newtype UserInput = UI { unInput :: ByteString } deriving Show

instance Arbitrary UserInput where
  arbitrary = UI . C8.pack <$> arbitrary

cipherInitNoError :: Cipher c => c -> ByteString -> c
cipherInitNoError _ k = case cipherInit k of
  CryptoPassed a -> a
  CryptoFailed e -> error (show e)

--------------------------------------------------------------------------------
newRNCryptorContext :: ByteString -> RNCryptorHeader -> RNCryptorContext
newRNCryptorContext userKey hdr =
  let eKey = generate (prfHMAC (undefined::SHA1)) (Parameters 10000 32) userKey (rncEncryptionSalt hdr)
      cipher =  cipherInitNoError (undefined::AES128) eKey
  in RNCryptorContext hdr userKey cipher
