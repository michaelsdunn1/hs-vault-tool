{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Unless otherwise specified, all IO functions in this module may
-- potentially throw 'HttpException' or 'VaultException'

module Network.VaultTool
    ( VaultAddress(..)
    , VaultUnsealKey(..)
    , VaultAuthToken(..)
    , VaultException(..)

    , VaultHealth(..)
    , vaultHealth

    , VaultConnection
    , connectToVault

    , vaultInit
    , VaultSealStatus(..)
    , vaultSealStatus
    , vaultSeal
    , VaultUnseal(..)
    , vaultUnseal

    , VaultMount(..)
    , VaultMountRead
    , VaultMountWrite
    , VaultMountConfig(..)
    , VaultMountConfigRead
    , VaultMountConfigWrite
    , vaultMounts
    , vaultMountTune
    , vaultMountSetTune
    , vaultNewMount
    , vaultUnmount

    , VaultSecretPath(..)
    , VaultSecretMetadata(..)
    , vaultWrite
    , vaultRead
    , vaultDelete
    , vaultList
    , isFolder
    , vaultListRecursive
    ) where

import Control.Exception (throwIO)
import Control.Monad (liftM)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.List (sortOn)
import Data.Text (Text)
import Network.HTTP.Client (Manager, newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import qualified Data.HashMap.Strict as H
import qualified Data.Text as T

import Network.VaultTool.Internal
import Network.VaultTool.Types

data VaultConnection = VaultConnection
    { _VaultConnection_AuthToken :: VaultAuthToken
    , _VaultConnection_VaultAddress :: VaultAddress
    , _VaultConnection_Manager :: Manager
    }

-- | <https://www.vaultproject.io/docs/http/sys-health.html>
--
-- See 'vaultHealth'
data VaultHealth = VaultHealth
    { _VaultHealth_Version :: Text
    , _VaultHealth_ServerTimeUtc :: Int
    , _VaultHealth_Initialized :: Bool
    , _VaultHealth_Sealed :: Bool
    , _VaultHealth_Standby :: Bool
    }
    deriving (Show, Eq, Ord)

instance FromJSON VaultHealth where
    parseJSON (Object v) =
        VaultHealth <$>
             v .: "version" <*>
             v .: "server_time_utc" <*>
             v .: "initialized" <*>
             v .: "sealed" <*>
             v .: "standby"
    parseJSON _ = fail "Not an Object"

vaultUrl :: VaultAddress -> String -> String
vaultUrl (VaultAddress addr) path = T.unpack addr ++ "/v1" ++ path

-- | https://www.vaultproject.io/docs/http/sys-health.html
vaultHealth :: VaultAddress -> IO VaultHealth
vaultHealth vaultAddress = do
    manager <- newManager tlsManagerSettings
    vaultRequestJSON manager "GET" (vaultUrl vaultAddress "/sys/health") [] (Nothing :: Maybe ()) expectedStatusCodes
    where
    expectedStatusCodes = [200, 429, 501, 503]

-- | Just initializes the 'VaultConnection' objects, does not actually make any
-- contact with the vault server. (That is also the explanation why there is no
-- function to disconnect)
connectToVault :: VaultAddress -> VaultAuthToken -> IO VaultConnection
connectToVault addr authToken = do
    manager <- newManager tlsManagerSettings
    pure VaultConnection
            { _VaultConnection_AuthToken = authToken
            , _VaultConnection_VaultAddress = addr
            , _VaultConnection_Manager = manager
            }

-- | <https://www.vaultproject.io/docs/http/sys-init.html>
--
-- See 'vaultInit'
data VaultInitResponse = VaultInitResponse
    { _VaultInitResponse_Keys :: [Text]
    , _VaultInitResponse_RootToken :: VaultAuthToken
    }
    deriving (Show, Eq, Ord)

instance FromJSON VaultInitResponse where
    parseJSON (Object v) =
        VaultInitResponse <$>
             v .: "keys" <*>
             v .: "root_token"
    parseJSON _ = fail "Not an Object"

-- | <https://www.vaultproject.io/docs/http/sys-init.html>
vaultInit
    :: VaultAddress
    -> Int -- ^ @secret_shares@: The number of shares to split the master key
           -- into
    -> Int -- ^ @secret_threshold@: The number of shares required to
           -- reconstruct the master key. This must be less than or equal to
           -- secret_shares
    -> IO ([VaultUnsealKey], VaultAuthToken) -- ^ master keys and initial root token
vaultInit addr secretShares secretThreshold = do
    let reqBody = object
            [ "secret_shares" .= secretShares
            , "secret_threshold" .= secretThreshold
            ]
    manager <- newManager tlsManagerSettings
    rsp <- vaultRequestJSON manager "PUT" (vaultUrl addr "/sys/init") [] (Just reqBody) [200]
    let VaultInitResponse{_VaultInitResponse_Keys, _VaultInitResponse_RootToken} = rsp
    pure (map VaultUnsealKey _VaultInitResponse_Keys, _VaultInitResponse_RootToken)

-- | <https://www.vaultproject.io/docs/http/sys-seal-status.html>
--
-- See 'vaultSealStatus'
data VaultSealStatus = VaultSealStatus
    { _VaultSealStatus_Sealed :: Bool
    , _VaultSealStatus_T :: Int -- ^ threshold
    , _VaultSealStatus_N :: Int -- ^ number of shares
    , _VaultSealStatus_Progress :: Int
    }
    deriving (Show, Eq, Ord)

instance FromJSON VaultSealStatus where
    parseJSON (Object v) =
        VaultSealStatus <$>
             v .: "sealed" <*>
             v .: "t" <*>
             v .: "n" <*>
             v .: "progress"
    parseJSON _ = fail "Not an Object"

vaultSealStatus :: VaultAddress -> IO VaultSealStatus
vaultSealStatus addr = do
    manager <- newManager tlsManagerSettings
    vaultRequestJSON manager "GET" (vaultUrl addr "/sys/seal-status") [] (Nothing :: Maybe ()) [200]

vaultSeal :: VaultConnection -> IO ()
vaultSeal VaultConnection{_VaultConnection_VaultAddress, _VaultConnection_Manager, _VaultConnection_AuthToken} = do
    _ <- vaultRequest _VaultConnection_Manager "PUT" (vaultUrl _VaultConnection_VaultAddress "/sys/seal") headers (Nothing :: Maybe ()) [204]
    pure ()
    where
    headers = [("X-Vault-Token", unVaultAuthToken _VaultConnection_AuthToken)]

-- | <https://www.vaultproject.io/docs/http/sys-unseal.html>
--
-- See 'vaultUnseal'
data VaultUnseal
    = VaultUnseal_Key VaultUnsealKey
    | VaultUnseal_Reset
    deriving (Show, Eq, Ord)

-- | <https://www.vaultproject.io/docs/http/sys-unseal.html>
vaultUnseal :: VaultAddress -> VaultUnseal -> IO VaultSealStatus
vaultUnseal addr unseal = do
    let reqBody = case unseal of
            VaultUnseal_Key (VaultUnsealKey key) -> object
                [ "key" .= key
                ]
            VaultUnseal_Reset -> object
                [ "reset" .= True
                ]
    manager <- newManager tlsManagerSettings
    vaultRequestJSON manager "PUT" (vaultUrl addr "/sys/unseal") [] (Just reqBody) [200]


type VaultMountRead = VaultMount Text VaultMountConfigRead
type VaultMountWrite = VaultMount (Maybe Text) (Maybe VaultMountConfigWrite)
type VaultMountConfigRead = VaultMountConfig Int
type VaultMountConfigWrite = VaultMountConfig (Maybe Int)

-- | <https://www.vaultproject.io/docs/http/sys-mounts.html>
data VaultMount a b = VaultMount
    { _VaultMount_Type :: Text
    , _VaultMount_Description :: a
    , _VaultMount_Config :: b
    }
    deriving (Show, Eq, Ord)

instance FromJSON VaultMountRead where
    parseJSON (Object v) =
        VaultMount <$>
             v .: "type" <*>
             v .: "description" <*>
             v .: "config"
    parseJSON _ = fail "Not an Object"

instance ToJSON VaultMountWrite where
    toJSON v = object
        [ "type" .= _VaultMount_Type v
        , "description" .= _VaultMount_Description v
        , "config" .= _VaultMount_Config v
        ]

-- | <https://www.vaultproject.io/docs/http/sys-mounts.html>
data VaultMountConfig a = VaultMountConfig
    { _VaultMountConfig_DefaultLeaseTtl :: a
    , _VaultMountConfig_MaxLeaseTtl :: a
    }
    deriving (Show, Eq, Ord)

instance FromJSON VaultMountConfigRead where
    parseJSON (Object v) =
        VaultMountConfig <$>
             v .: "default_lease_ttl" <*>
             v .: "max_lease_ttl"
    parseJSON _ = fail "Not an Object"

instance ToJSON VaultMountConfigWrite where
    toJSON v = object
        [ "default_lease_ttl" .= fmap formatSeconds (_VaultMountConfig_DefaultLeaseTtl v)
        , "max_lease_ttl" .= fmap formatSeconds (_VaultMountConfig_MaxLeaseTtl v)
        ]

formatSeconds :: Int -> String
formatSeconds n = show n ++ "s"

-- | <https://www.vaultproject.io/docs/http/sys-mounts.html>
--
-- For your convenience, the results are returned sorted (by the mount point)
vaultMounts :: VaultConnection -> IO [(Text, VaultMountRead)]
vaultMounts VaultConnection{_VaultConnection_VaultAddress, _VaultConnection_Manager, _VaultConnection_AuthToken} = do
    let reqPath = vaultUrl _VaultConnection_VaultAddress "/sys/mounts"
    rspObj <- vaultRequestJSON _VaultConnection_Manager "GET" reqPath headers (Nothing :: Maybe ()) [200]

    -- Vault 0.6.1 has a different format than previous versions.
    -- See <https://github.com/hashicorp/vault/issues/1965>
    --
    -- We do some detection to support both the new and the old format:
    let root = case H.lookup "data" rspObj of
            Nothing -> Object rspObj
            Just v -> v

    case parseEither parseJSON root of
        Left err -> throwIO $ VaultException_ParseBodyError "GET" reqPath (encode rspObj) err
        Right obj -> pure $ sortOn fst (H.toList obj)
    where
    headers = [("X-Vault-Token", unVaultAuthToken _VaultConnection_AuthToken)]

-- | <https://www.vaultproject.io/docs/http/sys-mounts.html>
vaultMountTune :: VaultConnection -> Text -> IO VaultMountConfigRead
vaultMountTune VaultConnection{_VaultConnection_VaultAddress, _VaultConnection_Manager, _VaultConnection_AuthToken} mountPoint = do
    vaultRequestJSON _VaultConnection_Manager "GET" (vaultUrl _VaultConnection_VaultAddress "/sys/mounts/" ++ T.unpack mountPoint ++ "/tune") headers (Nothing :: Maybe ()) [200]
    where
    headers = [("X-Vault-Token", unVaultAuthToken _VaultConnection_AuthToken)]

-- | <https://www.vaultproject.io/docs/http/sys-mounts.html>
vaultMountSetTune :: VaultConnection -> Text -> VaultMountConfigWrite -> IO ()
vaultMountSetTune VaultConnection{_VaultConnection_VaultAddress, _VaultConnection_Manager, _VaultConnection_AuthToken} mountPoint mountConfig = do
    let reqBody = mountConfig
    _ <- vaultRequest _VaultConnection_Manager "POST" (vaultUrl _VaultConnection_VaultAddress "/sys/mounts/" ++ T.unpack mountPoint ++ "/tune") headers (Just reqBody) [204]
    pure ()
    where
    headers = [("X-Vault-Token", unVaultAuthToken _VaultConnection_AuthToken)]

-- | <https://www.vaultproject.io/docs/http/sys-mounts.html>
vaultNewMount :: VaultConnection -> Text -> VaultMountWrite -> IO ()
vaultNewMount VaultConnection{_VaultConnection_VaultAddress, _VaultConnection_Manager, _VaultConnection_AuthToken} mountPoint vaultMount = do
    let reqBody = vaultMount
    _ <- vaultRequest _VaultConnection_Manager "POST" (vaultUrl _VaultConnection_VaultAddress "/sys/mounts/" ++ T.unpack mountPoint) headers (Just reqBody) [204]
    pure ()
    where
    headers = [("X-Vault-Token", unVaultAuthToken _VaultConnection_AuthToken)]

-- | <https://www.vaultproject.io/docs/http/sys-mounts.html>
vaultUnmount :: VaultConnection -> Text -> IO ()
vaultUnmount VaultConnection{_VaultConnection_VaultAddress, _VaultConnection_Manager, _VaultConnection_AuthToken} mountPoint = do
    _ <- vaultRequest _VaultConnection_Manager "DELETE" (vaultUrl _VaultConnection_VaultAddress "/sys/mounts/" ++ T.unpack mountPoint) headers (Nothing :: Maybe ()) [204]
    pure ()
    where
    headers = [("X-Vault-Token", unVaultAuthToken _VaultConnection_AuthToken)]

data VaultSecretMetadata = VaultSecretMetadata
    { _VaultSecretMetadata_leaseDuration :: Int
    , _VaultSecretMetadata_leaseId :: Text
    , _VauleSecretMetadata_renewable :: Bool
    }
    deriving (Show, Eq {- TODO Ord #-})

instance FromJSON VaultSecretMetadata where
    parseJSON (Object v) =
        VaultSecretMetadata <$>
            v .: "lease_duration" <*>
            v .: "lease_id" <*>
            v .: "renewable"
    parseJSON _ = fail "Not an Object"

-- | <https://www.vaultproject.io/docs/secrets/generic/index.html>
--
-- The value that you give must encode as a JSON object
vaultWrite :: ToJSON a => VaultConnection -> VaultSecretPath -> a -> IO ()
vaultWrite VaultConnection{_VaultConnection_VaultAddress, _VaultConnection_Manager, _VaultConnection_AuthToken} (VaultSecretPath location) value = do
    let reqBody = value
    _ <- vaultRequest _VaultConnection_Manager "POST" (vaultUrl _VaultConnection_VaultAddress "/" ++ T.unpack location) headers (Just reqBody) [204]
    pure ()
    where
    headers = [("X-Vault-Token", unVaultAuthToken _VaultConnection_AuthToken)]

vaultRead
    :: FromJSON a
    => VaultConnection
    -> VaultSecretPath
    -> IO (VaultSecretMetadata, Either (Value, String) a) -- ^ A 'Left' result
                                                          -- means that the
                                                          -- secret's "data"
                                                          -- could not be
                                                          -- parsed into the
                                                          -- data structure
                                                          -- that you
                                                          -- requested.
                                                          --
                                                          -- You will get the
                                                          -- "data" as a raw
                                                          -- 'Value' as well as
                                                          -- the error message
                                                          -- from the parse
                                                          -- failure
vaultRead VaultConnection{_VaultConnection_VaultAddress, _VaultConnection_Manager, _VaultConnection_AuthToken} (VaultSecretPath location) = do
    let path = vaultUrl _VaultConnection_VaultAddress "/" ++ T.unpack location
    rspObj <- vaultRequestJSON _VaultConnection_Manager "GET" path headers (Nothing :: Maybe ()) [200]
    case parseEither parseJSON (Object rspObj) of
        Left err -> throwIO $ VaultException_ParseBodyError "GET" path (encode rspObj) err
        Right metadata -> case parseEither (.: "data") rspObj of
            Left err -> throwIO $ VaultException_ParseBodyError "GET" path (encode rspObj) err
            Right dataObj -> case parseEither parseJSON (Object dataObj) of
                Left err -> pure (metadata, Left (Object dataObj, err))
                Right data_ -> pure (metadata, Right data_)

    where
    headers = [("X-Vault-Token", unVaultAuthToken _VaultConnection_AuthToken)]

-- | <https://www.vaultproject.io/docs/secrets/generic/index.html>
vaultDelete :: VaultConnection -> VaultSecretPath -> IO ()
vaultDelete VaultConnection{_VaultConnection_VaultAddress, _VaultConnection_Manager, _VaultConnection_AuthToken} (VaultSecretPath location) = do
    _ <- vaultRequest _VaultConnection_Manager "DELETE" (vaultUrl _VaultConnection_VaultAddress "/" ++ T.unpack location) headers (Nothing :: Maybe ()) [204]
    pure ()
    where
    headers = [("X-Vault-Token", unVaultAuthToken _VaultConnection_AuthToken)]

data VaultListResult = VaultListResult [Text]

instance FromJSON VaultListResult where
    parseJSON (Object v) = do
        data_ <- v .: "data"
        keys <- data_ .: "keys"
        pure (VaultListResult keys)
    parseJSON _ = fail "Not an Object"

-- | <https://www.vaultproject.io/docs/secrets/generic/index.html>
--
-- This will normalise the results to be full secret paths.
--
-- Will return only secrets that in the are located in the folder hierarchy
-- directly below the given folder.
--
-- Use 'isFolder' to check if whether each result is a secret or a subfolder.
--
-- The order of the results is unspecified.
--
-- To recursively retrieve all of the secrets use 'vaultListRecursive'
vaultList :: VaultConnection -> VaultSecretPath -> IO [VaultSecretPath]
vaultList VaultConnection{_VaultConnection_VaultAddress, _VaultConnection_Manager, _VaultConnection_AuthToken} (VaultSecretPath location) = do
    VaultListResult keys <- vaultRequestJSON _VaultConnection_Manager "LIST" (vaultUrl _VaultConnection_VaultAddress "/" ++ T.unpack location) headers (Nothing :: Maybe ()) [200]
    pure $ map (VaultSecretPath . (withTrailingSlash `T.append`)) keys
    where
    headers = [("X-Vault-Token", unVaultAuthToken _VaultConnection_AuthToken)]
    withTrailingSlash
        | T.null location = "/"
        | T.last location == '/' = location
        | otherwise = location `T.snoc` '/'

-- | Does the path end with a '/' character?
--
-- Meant to be used on the results of 'vaultList'
isFolder :: VaultSecretPath -> Bool
isFolder (VaultSecretPath path)
    | T.null path = False
    | otherwise = T.last path == '/'

-- | Recursively calls 'vaultList' to retrieve all of the secrets in a folder
-- (including all subfolders and sub-subfolders, etc...)
--
-- There will be no folders in the result.
--
-- The order of the results is unspecified.
vaultListRecursive :: VaultConnection -> VaultSecretPath -> IO [VaultSecretPath]
vaultListRecursive conn location = do
    paths <- vaultList conn location
    (flip concatMapM) paths $ \path -> do
        if isFolder path
            then vaultListRecursive conn path
            else pure [path]

concatMapM        :: (Monad m) => (a -> m [b]) -> [a] -> m [b]
concatMapM f xs   =  liftM concat (mapM f xs)
