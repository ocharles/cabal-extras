{-# LANGUAGE BangPatterns #-}
module CabalDocspec.Lexer (
    -- * Passes
    needsCppPass,
    L.lexerPass0,
    Pos,
    -- * Comments
    Comment (..),
    extractComments,
    extractDocstrings,
    -- ** Stripping comments
    dropComments,
) where

import Peura

import Data.Char              (toLower)
import Data.List              (stripPrefix, init)
import Language.Haskell.Lexer (Pos, PosToken)
import Text.Read              (read)

import qualified Distribution.ModuleName as C
import qualified Language.Haskell.Lexer  as L
import qualified Text.Parsec             as P

import CabalDocspec.Doctest.Extract
import CabalDocspec.Located

-------------------------------------------------------------------------------
-- Needs CPP pass
-------------------------------------------------------------------------------

-- | Whether input needs a CPP pass.
--
-- Looks for leading LANGUAGE pragmas for occurence of CPP.
--
needsCppPass :: String -> Maybe [PosToken]
needsCppPass input = go tokens
  where
    tokens = L.lexerPass0 input

    go :: [PosToken] -> Maybe [PosToken]
    go []                             = Just tokens
    go ((L.Commentstart,  _):xs)      = go xs
    go ((L.Comment,  _):xs)           = go xs
    go ((L.NestedComment, (_, s)):xs)
        | "CPP" `elem` parseLanguagePragma s
        = Nothing

        | otherwise
        = go xs
    go _                              = Just tokens

-------------------------------------------------------------------------------
-- Comment
-------------------------------------------------------------------------------

data Comment
    = LineCommentBlock Pos String
    | NestedComment Pos String
  deriving Show

extractComments :: [PosToken] -> [Comment]
extractComments = go 0 where
    go :: Int -> [PosToken] -> [Comment]
    go _diff [] = []
    -- normal comments, -- foo
    go diff ((L.Commentstart, (pos, s)) : (L.Comment, (_pos, str)) : next) =
        goLines diff (adjustPos diff pos) (\n -> s ++ str ++ n) next
    -- nested comments, {- foo -}
    go diff ((L.NestedComment, (pos, s)) : next) = case parseLinePragma s of
        Just l  -> go (l - L.line pos - 1) next
        Nothing -> NestedComment (adjustPos diff pos) s : go diff next
    -- other things are skipped
    go diff (_ : next) = go diff next

    goLines :: Int -> Pos -> (String -> String) -> [PosToken] -> [Comment]
    goLines diff !pos !acc ((L.Commentstart, (_, s)) : (L.Comment, (_, str)) : next) =
        goLines diff pos (acc . (s ++) . (str ++)) next
    goLines diff !pos !acc next = LineCommentBlock pos (acc "") : go diff next

    -- adjust position based on {-# LINE #-} pragmas
    adjustPos diff pos = pos { L.line = L.line pos + diff }

-------------------------------------------------------------------------------
-- Process expressions
-------------------------------------------------------------------------------

dropComments :: String -> String
dropComments
    = init
    . concat
    . map wsComment
    . L.lexerPass0
    . (++ "\n") -- work around https://github.com/yav/haskell-lexer/issues/9
  where
    wsComment :: PosToken -> String
    wsComment (L.Commentstart,  (_, s)) = map ws s
    wsComment (L.NestedComment, (_, s)) = map ws s
    wsComment (L.Comment,       (_, s)) = map ws s
    wsComment (_,               (_, s)) =        s

    ws c = if isSpace c then c else ' '

-------------------------------------------------------------------------------
-- Extract docstrings
-------------------------------------------------------------------------------

extractDocstrings :: C.ModuleName -> [Comment] -> Module (Located String)
extractDocstrings modname comments = Module
    { moduleName    = modname
    , moduleSetup   = setup
    , moduleContent =
        [ c
        | c@(L _ s) <- comments'
        , case s of
            '|':_ -> True
            '^':_ -> True
            _     -> False
        ]
    }
  where
    setup = listToMaybe
        [ c
        | c@(L _ s) <- comments'
        , case stripPrefix "$setup" s of
            Just []    -> True
            Just (x:_) -> isSpace x
            Nothing    -> False
        ]

    comments' =
        [ L (commentPos c) s
        | c <- comments
        , let s = commentString c
        ]

commentString :: Comment -> String
commentString (NestedComment _ ('{' : '-' : rest)) = dropWhile isSpace $ dropTrailingClose rest
commentString (NestedComment _ s)                  = dropWhile isSpace s
commentString (LineCommentBlock _ s)               = dropWhile isSpace $ unlines $ map (dropWhile (== '-')) $ lines s

commentPos :: Comment -> Pos
commentPos (NestedComment p _)    = p
commentPos (LineCommentBlock p _) = p

dropTrailingClose :: String -> String
dropTrailingClose "-}"   = ""
dropTrailingClose (c:cs) = c : dropTrailingClose cs
dropTrailingClose []     = []


-------------------------------------------------------------------------------
-- Pragma parsers
-------------------------------------------------------------------------------

parseLinePragma :: String -> Maybe Int
parseLinePragma input =
    case P.parse linePragmaP "<input>" input of
        Right res -> Just res
        Left _    -> Nothing
  where
    linePragmaP :: P.Parsec String () Int
    linePragmaP = do
        _ <- P.string "{-#"
        skipSpacesP
        token <- tokenP
        unless (map toLower token == "line") $ fail $ "unexpected " ++ token
        skipSpacesP
        read <$> some (P.satisfy isDigit)

parseLanguagePragma :: String -> [String]
parseLanguagePragma input =
    case P.parse languagePragmaP "<input>" input of
        Right res -> res
        Left _    -> []
  where
    languagePragmaP :: P.Parsec String () [String]
    languagePragmaP = do
        _ <- P.string "{-#"
        skipSpacesP
        token <- tokenP
        unless (map toLower token == "language") $ fail $ "unexpected " ++ token
        skipSpacesP

        P.sepBy1 (tokenP <* skipSpacesP) (P.char ',' *> skipSpacesP)

skipSpacesP :: P.Parsec String () ()
skipSpacesP = P.skipMany P.space

tokenP :: P.Parsec String () String
tokenP = some $ P.satisfy isAlphaNum
