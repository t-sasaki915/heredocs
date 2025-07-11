{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE TemplateHaskellQuotes #-}

module Text.Heredoc
    ( heredoc
    , heredocFile
    ) where

import           Control.Arrow                       (first, second)
import           Data.Functor                        (($>))
import           Data.List                           (intercalate)
import           Language.Haskell.TH
import           Language.Haskell.TH.Quote           (QuasiQuoter (..))
import           Text.ParserCombinators.Parsec       hiding (Line)
import           Text.ParserCombinators.Parsec.Error (errorMessages,
                                                      messageString)

heredoc :: QuasiQuoter
heredoc = QuasiQuoter
    { quoteExp  = heredocFromString
    , quotePat  = undefined
    , quoteType = undefined
    , quoteDec  = undefined
    }

heredocFile :: FilePath -> Q Exp
heredocFile fp = do
    content <- runIO $ readFile fp
    heredocFromString content

heredocFromString :: String -> Q Exp
heredocFromString = either err (concatToQExp . arrange) . parse doc "heredoc"
    where
        err = infixE <$> Just . pos <*> pure (varE '(<>)) <*> Just . msg
        pos = litE . stringL <$> (show . errorPos)
        msg = litE . stringL <$> (concatMap messageString . errorMessages)

type Indent     = Int
type Line'      = (Indent, Line)
type ChildBlock = [Line']
type AltFlag    = Bool

data InLine = Raw String
            | Quoted [Expr]
            deriving Show

data Line = CtrlForall [Expr] [Expr] ChildBlock
          | CtrlMaybe AltFlag [Expr] [Expr] ChildBlock ChildBlock
          | CtrlNothing
          | CtrlIf AltFlag [Expr] ChildBlock ChildBlock
          | CtrlElse
          | CtrlCase [Expr] [([Expr], ChildBlock)]
          | CtrlOf [Expr]
          | CtrlLet [Expr] [Expr] ChildBlock
          | Normal [InLine]
          deriving Show

data Expr = S String
          | I Integer
          | W
          | A String Expr
          | V String
          | V' String
          | C String
          | O String
          | O' String
          | E [Expr]
          | T [[Expr]]
          | L [[Expr]]
          | N
          deriving Show

eol :: Parser String
eol = try (string "\n\r")
  <|> try (string "\r\n")
  <|> string "\n"
  <|> string "\r"
  <?> fail "end of line"

spaceTabs :: Parser String
spaceTabs = many (oneOf " \t")

doc :: Parser [(Indent, Line)]
doc = line `sepBy` eol

line :: Parser (Indent, Line)
line = (,) <$> indent <*> contents

indent :: Parser Indent
indent = sum <$>
    many ((char ' ' $> 1) <|> (char '\t' *> fail "Tabs are not allowed in indentation"))

contents :: Parser Line
contents = try ctrlForall
       <|> try ctrlMaybe
       <|> try ctrlNothing
       <|> try ctrlIf
       <|> try ctrlElse
       <|> try ctrlCase
       <|> try ctrlOf
       <|> try ctrlLet
       <|> normal

ctrlForall :: Parser Line
ctrlForall = CtrlForall <$> (string "$forall" *> spaceTabs *> binding <* spaceTabs <* string "<-" <* spaceTabs) <*> expr <*> pure []

ctrlMaybe :: Parser Line
ctrlMaybe = CtrlMaybe False <$> (string "$maybe" *> spaceTabs *> binding <* spaceTabs <* string "<-" <* spaceTabs) <*> expr <*> pure [] <*> pure []

ctrlNothing :: Parser Line
ctrlNothing = string "$nothing" *> spaceTabs $> CtrlNothing

ctrlIf :: Parser Line
ctrlIf = CtrlIf False <$> (string "$if" *> spaceTabs *> expr <* spaceTabs) <*> pure [] <*> pure []

ctrlElse :: Parser Line
ctrlElse = string "$else" *> spaceTabs $> CtrlElse

ctrlCase :: Parser Line
ctrlCase = CtrlCase <$> (string "$case" *> spaceTabs *> expr <* spaceTabs) <*> pure []

ctrlOf :: Parser Line
ctrlOf = CtrlOf <$> (string "$of" *> spaceTabs *> binding <* spaceTabs)

ctrlLet :: Parser Line
ctrlLet = CtrlLet <$> (string "$let" *> spaceTabs *> binding <* spaceTabs <* string "=" <* spaceTabs) <*> expr <*> pure []

binding :: Parser [Expr]
binding = spaceTabs *> many1 (try (A <$> var <* char '@' <*> term) <|> term)
    where
        term :: Parser Expr
        term =
            ( T <$> tuple
          <|> (try (nil $> N) <|> try (L <$> list) <|> try (O <$> string ":"))
          <|> (try (V <$> ((<>) <$> wild <*> many1 (alphaNum <|> oneOf "_'"))) <|> try (wild $> W) <|> V <$> var)
          <|> C <$> con
            ) <* spaceTabs

expr :: Parser [Expr]
expr = spaceTabs *> many1 (try (A <$> var <* char '@' <*> term) <|> term)
    where
        term :: Parser Expr
        term =
            ( S <$> str
          <|> T <$> tuple
          <|> (try (nil $> N) <|> try (L <$> list) <|> try (O <$> op))
          <|> (try (O' <$> op') <|> try (E <$> subexp))
          <|> V <$> var'
          <|> (try (V <$> ((<>) <$> wild <*> many1 (alphaNum <|> oneOf "_'"))) <|> try (wild $> W) <|> V <$> var)
          <|> C <$> con
          <|> I <$> integer
            ) <* spaceTabs


tuple :: Parser [[Expr]]
tuple = char '(' *> sepBy expr (char ',')  <* char ')'

list :: Parser [[Expr]]
list = char '[' *> sepBy expr (char ',') <* char ']'

integer :: Parser Integer
integer = read <$> many1 digit

str :: Parser String
str = char '"' *> many (noneOf "\\\"" <|> try (string "\\\"" $> '"')) <* char '"'

subexp :: Parser [Expr]
subexp = char '(' *> expr <* char ')'

var :: Parser String
var = try ((+.+) <$> modul <*> v) <|> v
    where
        x +.+ y = x <> "." <> y

        v :: Parser String
        v = (:) <$> lower <*> many (alphaNum <|> oneOf "_'")

modul :: Parser String
modul = try (intercalate "." <$> many1 (mod' <* char '.')) <|> mod'
    where
        mod' :: Parser String
        mod' = (:) <$> upper <*> many alphaNum

var' :: Parser String
var' = char '`' *> var <* char '`'

wild :: Parser String
wild = string "_"

nil :: Parser String
nil = string "[]"

con :: Parser String
con = (:) <$> upper <*> many (alphaNum <|> oneOf "_'")

op :: Parser String
op = many1 (oneOf ":!#$%&*+./<=>?@\\^|-~")

op' :: Parser String
op' = char '(' *> op <* char ')'

normal :: Parser Line
normal = Normal <$> many (try quoted <|> try raw' <|> try raw)

quoted :: Parser InLine
quoted = Quoted <$> (string "${" *> expr <* string "}")

raw' :: Parser InLine
raw' = Raw <$> ((:) <$> char '$' <*> ((:) <$> noneOf "{" <*> many (noneOf "$\n\r")))

raw :: Parser InLine
raw = Raw <$> many1 (noneOf "$\n\r")

arrange :: [(Indent, Line)] -> [(Indent, Line)]
arrange = norm . rev . foldl (flip push) []
    where
        isCtrlNothing (_, CtrlNothing) = True
        isCtrlNothing _                = False

        isCtrlElse (_, CtrlElse) = True
        isCtrlElse _             = False

        isCtrlOf (_, CtrlOf _) = True
        isCtrlOf _             = False

        push :: Line' -> [Line'] -> [Line']
        push x []                    = [x]
        push x ss'@((_, Normal _):_) = x:ss'

        push x@(i, _) ss'@((j, CtrlForall b e body):ss)
            | i > j     = (j, CtrlForall b e (push x body)):ss
            | otherwise = x:ss'

        push x@(i, _) ss'@((j, CtrlLet b e body):ss)
            | i > j     = (j, CtrlLet b e (push x body)):ss
            | otherwise = x:ss'

        push x@(i, _) ss'@((j, CtrlMaybe flg b e body alt):ss)
            | i > j =
                if flg
                    then (j, CtrlMaybe flg b e body (push x alt)):ss
                    else (j, CtrlMaybe flg b e (push x body) alt):ss

            | i == j && isCtrlNothing x =
                if flg
                    then error "too many $nothing found"
                    else (j, CtrlMaybe True b e body alt):ss

            | otherwise = x:ss'

        push _ ((_, CtrlNothing):_) = error "orphan $nothing found"

        push x@(i, _) ss'@((j, CtrlIf flg e body alt):ss)
            | i > j =
                if flg
                    then (j, CtrlIf flg e body (push x alt)):ss
                    else (j, CtrlIf flg e (push x body) alt):ss

            | i == j && isCtrlElse x =
                if flg
                    then error "too many $else found"
                    else (j, CtrlIf True e body alt):ss

            | otherwise = x:ss'

        push _ ((_, CtrlElse):_) = error "orphan $else found"

        push x@(i, _) ss'@((j, CtrlCase e alts):ss)
            | i > j = (j, CtrlCase e (push' x alts)):ss
            | otherwise =
                if isCtrlOf x
                    then error "orphan $of found"
                    else x:ss'

        push _ ((_, CtrlOf _):_) = error "orphan $of found"

        push' __@(_, CtrlOf e) alts = (e, []):alts
        push' _ []                  = error "$of not found"
        push' x ((e, body):alts)    = (e, push x body):alts

        rev :: [Line'] -> [Line']
        rev = foldr (\x xs -> xs <> [rev' x]) []
        rev' :: Line' -> Line'
        rev' x@(_, Normal _) = x
        rev' (i, CtrlForall b e body)
            = (i, CtrlForall b e (rev body))
        rev' (i, CtrlLet b e body)
            = (i, CtrlLet b e (rev body))
        rev' (i, CtrlMaybe flg b e body alt)
            = (i, CtrlMaybe flg b e (rev body) (rev alt))
        rev' (i, CtrlIf flg e body alt)
            = (i, CtrlIf flg e (rev body) (rev alt))
        rev' (i, CtrlCase e alts)
            = (i, CtrlCase e (map (second rev) $ reverse alts))
        rev' (_, CtrlNothing)
            = error "impossible"
        rev' (_, CtrlElse)
            = error "impossible"
        rev' (_, CtrlOf _)
            = error "impossible"

        norm :: [Line'] -> [Line']
        norm = map norm'
            where
                norm' :: Line' -> Line'
                norm' x@(_, Normal _) = x

                norm' (i, CtrlForall b e body) =
                    (i, CtrlForall b e (normsub i body <> blockEnd))

                norm' (i, CtrlLet b e body) =
                    (i, CtrlLet b e (normsub i body <> blockEnd))

                norm' (i, CtrlMaybe flg b e body alt) =
                    (i, CtrlMaybe flg b e (normsub i body <> blockEnd) (normsub i alt <> blockEnd))

                norm' (i, CtrlIf flg e body alt) =
                    (i, CtrlIf flg e (normsub i body <> blockEnd) (normsub i alt <> blockEnd))

                norm' (i, CtrlCase e alts) =
                    (i, CtrlCase e (map (second ((<> blockEnd) . normsub i)) alts))

                norm' (_, CtrlNothing) = error "orphan $nothing found"
                norm' (_, CtrlElse)    = error "orphan $else found"
                norm' (_, CtrlOf _)    = error "orphan $of found"

                normsub :: Indent -> [Line'] -> [Line']
                normsub i body =
                    let j = minimum (map fst body)
                        deIndent n = i + (n - j) in
                            norm $ map (first deIndent) body

                blockEnd :: [Line']
                blockEnd = [(0, Normal [])]

class ToQPat a where
    toQPat :: a -> Q Pat
    concatToQPat :: [a] -> Q Pat

instance ToQPat Expr where
    toQPat (S s)   = litP (stringL s)
    toQPat (I i)   = litP (integerL i)
    toQPat W       = wildP
    toQPat (V v)   = varP (mkName v)
    toQPat (O o)   = varP (mkName o)
    toQPat (E e)   = concatToQPat e
    toQPat (C c)   = conP (mkName c) []
    toQPat (T [t]) = concatToQPat t
    toQPat (T t)   = tupP $ map concatToQPat t
    toQPat (A a e) = asP (mkName a) $ toQPat e
    toQPat (V' _)  = error "impossible"
    toQPat (O' _)  = error "impossible"
    toQPat (L _)   = error "impossible"
    toQPat N       = error "impossible"

    -- special case for list
    concatToQPat (x:O ":":xs) = infixP
        (toQPat x)
        (mkName ":")
        (concatToQPat xs)

    concatToQPat ((C c):args) = conP
        (mkName c)
        (map toQPat args)

    concatToQPat ((V v):_)   = varP (mkName v) -- OK?
    concatToQPat [p@(T _)]   = toQPat p -- OK?
    concatToQPat [W]         = wildP -- OK?
    concatToQPat [p@(A _ _)] = toQPat p

    concatToQPat _ = error "don't support this pattern"

class ToQExp a where
    toQExp :: a -> Q Exp
    concatToQExp :: [a] -> Q Exp

instance ToQExp Expr where
    toQExp (S s)   = litE (stringL s)
    toQExp (I i)   = litE (integerL i)
    toQExp (V v)   = varE (mkName v)
    toQExp (O o)   = varE (mkName o)
    toQExp (E e)   = concatToQExp e
    toQExp (C c)   = conE (mkName c)
    toQExp (T [t]) = concatToQExp t
    toQExp (T t)   = tupE $ map concatToQExp t
    toQExp N       = listE []
    toQExp (L l)   = listE $ map concatToQExp l

    toQExp W       = error "wildcard is NOT legal expression"
    toQExp (A _ _) = error "impossible"
    toQExp (V' _)  = error "impossible"
    toQExp (O' _)  = error "impossible"

    concatToQExp = concatToQ' Nothing
        where
            concatToQ' (Just acc) []      = acc
            concatToQ' Nothing    [x]     = toQExp x
            concatToQ' Nothing    (x:xs') = concatToQ' (Just (toQExp x)) xs'
            concatToQ' Nothing []         = error "impossible"

            -- spacial case for list
            concatToQ' (Just acc) ((O ":"):xs') = infixE
                (Just acc)
                (conE (mkName ":"))
                (Just (concatToQExp xs'))

            concatToQ' (Just acc) ((O o):xs') = infixE
                (Just acc)
                (varE (mkName o))
                (Just (concatToQExp xs'))

            concatToQ' (Just acc) ((V' v'):xs') = infixE
                (Just acc)
                (varE (mkName v'))
                (Just (concatToQExp xs'))

            concatToQ' (Just acc) (x:xs') = concatToQ'
                (Just (appE acc (toQExp x)))
                xs'

instance ToQExp InLine where
    toQExp (Raw s)        = litE (stringL s)
    toQExp (Quoted expr') = concatToQExp expr'

    concatToQExp []     = litE (stringL "")
    concatToQExp (x:xs) = infixE
        (Just (toQExp x))
        (varE '(<>))
        (Just (concatToQExp xs))

instance ToQExp Line where
    toQExp (Normal xs) = concatToQExp xs

    toQExp (CtrlForall b e body) =
        appE
            ( appE
                ( appE
                    (varE 'foldr)
                    ( lamE
                        [concatToQPat b]
                        ( infixE
                            (Just (concatToQExp body))
                            (varE '(<>))
                            Nothing
                        )
                    )
                )
                (litE (stringL ""))
            )
            (concatToQExp e)

    toQExp (CtrlMaybe _ b e body alt) = caseE
        (concatToQExp e)
        [ match (conP 'Just [concatToQPat b])
                (normalB (concatToQExp body))
                []
        , match (conP 'Nothing [])
                (normalB (concatToQExp alt))
                []
        ]

    toQExp (CtrlIf _ e body alt) = condE
        (concatToQExp e)
        (concatToQExp body)
        (concatToQExp alt)

    toQExp (CtrlCase e alts) = caseE
        (concatToQExp e)
        (map mkMatch alts)
        where
            mkMatch (e', body) = match
                (concatToQPat e')
                (normalB (concatToQExp body))
                []

    toQExp (CtrlLet b e body) = letE
        [valD (concatToQPat b) (normalB $ concatToQExp e) []]
        (concatToQExp body)

    toQExp CtrlElse    = error "illegal $else found"
    toQExp (CtrlOf _)  = error "illegal $of found"
    toQExp CtrlNothing = error "impossible"

    concatToQExp []     = error "impossible"
    concatToQExp [x]    = toQExp x
    concatToQExp (x:xs) = infixE
        (Just (toQExp x))
        (varE '(<>))
        (Just (concatToQExp xs))

instance ToQExp Line' where
    toQExp (n, x@(Normal _)) = infixE
        (Just (litE (stringL (replicate n ' '))))
        (varE '(<>))
        (Just (toQExp x))

    toQExp (_, x) = toQExp x -- Ctrl*

    concatToQExp [] = litE (stringL "")

    concatToQExp (x@(_, Normal _):y:ys) = infixE
        (Just (infixE (Just (toQExp x))
        (varE '(<>))
        (Just (litE (stringL "\n")))))
        (varE '(<>))
        (Just (concatToQExp (y:ys)))

    concatToQExp (x@(_, Normal _):xs) = infixE
        (Just (toQExp x))
        (varE '(<>))
        (Just (concatToQExp xs))

    concatToQExp (x:xs) = infixE
        (Just (toQExp x))
        (varE '(<>))
        (Just (concatToQExp xs))
