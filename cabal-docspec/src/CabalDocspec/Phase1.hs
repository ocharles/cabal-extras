module CabalDocspec.Phase1 (
    phase1,
) where

import Peura

import qualified Distribution.ModuleName      as C
import qualified Distribution.Types.BuildInfo as C
import qualified Distribution.Types.Version   as C

import CabalDocspec.Cpp
import CabalDocspec.Doctest.Extract
import CabalDocspec.Lexer
import CabalDocspec.Located
import CabalDocspec.Trace

-- | First phase.
--
-- Read file, extract doctest blocks.
--
-- In particular, this runs CPP preprocessing if needed.
phase1
    :: TracerPeu r Tr
    -> GhcInfo
    -> [PackageIdentifier] -- ^ dependencies
    -> C.BuildInfo
    -> C.ModuleName
    -> Path Absolute
    -> Peu r (Module (Located String))
phase1 tracer ghcInfo pkgIds bi modname modpath = do
    traceApp tracer $ TracePhase1 modname modpath

    contents <- fromUTF8BS <$> readByteString modpath

    -- lex the input.
    -- If it includes {-# LANGUAGE CPP #-}, then cpphs and re-lex.
    comments <- case needsCppPass contents of
        Just tokens ->
            return $ extractComments tokens
        Nothing -> do
            contents' <- cpphs tracer pkgIds cppDefines modpath contents
            return $ extractComments $ lexerPass0 contents'

    -- extract docstrings from all comments
    return $ extractDocstrings modname comments
  where
    cppDefines :: [(String, String)]
    cppDefines =
        [ ("__GLASGOW_HASKELL__", cppGhcVersion (ghcVersion ghcInfo))
        ] ++
        [ d'
        | d <- C.cppOptions bi
        , Just d' <- return (parseDefineFlag d)
        ]

cppGhcVersion :: Version -> String
cppGhcVersion v = case C.versionNumbers v of
    []      -> "0"
    (x:[])  -> show (x * 100)
    (x:y:_) -> show (x * 100 + y)

parseDefineFlag :: String -> Maybe (String, String)
parseDefineFlag ('-' : 'D' : rest) =
    case after of
        []        -> Nothing
        '=':value -> Just (before, value)
        _         -> Nothing -- shouldn't happen
  where
    (before, after) = span (/= '=') rest

parseDefineFlag _ = Nothing
