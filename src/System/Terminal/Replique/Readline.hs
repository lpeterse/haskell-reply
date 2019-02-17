module System.Terminal.Replique.Readline where

import           Control.Monad
import           Control.Monad.State
import           Data.Char
import           Data.Maybe
import qualified Data.Text                        as T
import           Data.Text.Prettyprint.Doc    hiding (width)
import           Prelude                      hiding (putChar)

import           System.Terminal
import           System.Terminal.Replique.Monad
import           System.Terminal.Replique.Readable

readLine :: (MonadReplique m, Readable a) => Doc (Attribute m) -> m (Maybe a)
readLine prompt = do
    window <- getWindowSize
    cursor <- do
        pos <- getCursorPosition
        if col pos == 0
            then pure pos
            else putLn >> pure (Position (row pos + 1) 0)
    evalStateT (putReadLineState >> run) ReadLineState
        { rlWindow        = window
        , rlPosition      = cursor
        , rlPrompt        = layoutSmart defaultLayoutOptions (prompt <> space)
        , rlInputString   = ""
        , rlInputCursor   = 0
        }

run :: (MonadReplique m, Readable a) => StateT (ReadLineState m) m (Maybe a)
run = lift awaitEvent >>= \case
    Left Interrupt -> lift interrupt
    Right ev -> case ev of
        KeyEvent EnterKey _ -> quit
        KeyEvent (CharKey c) mods
            | c == 'A' && mods == ctrlKey -> do
                moveToLineBegin
                run
            | c == 'E' && mods == ctrlKey -> do
                moveToLineEnd
                run
            | c == 'D' && mods == ctrlKey -> do
                quitWith Nothing
            | c == 'L' && mods == ctrlKey -> do
                clear
                run
            | mods == mempty -> do
                insertChar c
                run
            | otherwise -> do
                run
        KeyEvent DeleteKey _ -> do
            delete
            run
        KeyEvent BackspaceKey _ -> do
            deleteBackward
            run
        KeyEvent (ArrowKey Leftwards) mods
            | mods == ctrlKey -> do 
                moveLeftWord
                run
            | otherwise       -> do
                moveLeft
                run
        KeyEvent (ArrowKey Rightwards) mods
            | mods == ctrlKey -> do
                moveRightWord
                run
            | otherwise -> do
                moveRight
                run
        _ -> run
    where
        quit = do
            st <- get
            case readText (T.pack $ rlInputString st) of
                Left failure -> undefined -- FIXME
                Right result -> quitWith (Just result)
        quitWith result = do
            st <- get
            lift do 
                setCursorPosition (rlInputEndPosition st)
                putLn
                flush
            pure result

---------------------------------------------------------------------------------------------------
-- READLINE STATE
---------------------------------------------------------------------------------------------------

data ReadLineState m
    = ReadLineState 
    { rlWindow        :: Size
    , rlPosition      :: Position
    , rlPrompt        :: SimpleDocStream (Attribute m)
    , rlInputString   :: String
    , rlInputCursor   :: Int
    }

rlInputBeginPosition :: ReadLineState m -> Position
rlInputBeginPosition st = posInputBegin
    where
        size            = rlWindow st
        pos             = rlPosition st
        posInputBegin   = posPlusSimpleDocStream size pos (rlPrompt st)

rlInputEndPosition :: ReadLineState m -> Position
rlInputEndPosition st = posInputEnd
    where
        size            = rlWindow st
        posInputBegin   = rlInputBeginPosition st
        posInputEnd     = posPlus size posInputBegin $ length $ rlInputString st

putReadLineStateDiff :: MonadTerminal m => ReadLineState m -> StateT (ReadLineState m) m ()
putReadLineStateDiff newSt = do
    put newSt
    putReadLineState -- TODO

putReadLineState :: MonadTerminal m => StateT (ReadLineState m) m ()
putReadLineState = do
    st <- get
    let size            = rlWindow st
        pos             = rlPosition st
        posInputStart   = posPlusSimpleDocStream size pos (rlPrompt st)
        posInputEnd     = posPlus size posInputStart (length $ rlInputString st)
        posInputCursor  = posPlus size posInputStart (rlInputCursor st)
        scrolled        = height size <= row posInputEnd
        pos'
            | scrolled  = posPlusRows size pos (-1)
            | otherwise = pos
        posInputCursor'
            | scrolled  = posPlusRows size posInputCursor (-1)
            | otherwise = posInputCursor
    lift do
        hideCursor
        setCursorPosition pos
        eraseInLine EraseAll
        eraseInDisplay EraseForward
        putSimpleDocStream (rlPrompt st)
        putString (rlInputString st)
        putChar ' ' -- overcome auto-wrap laziness
        showCursor
        setCursorPosition posInputCursor'
        flush
    put st { rlPosition = pos' }

clear :: MonadTerminal m => StateT (ReadLineState m) m ()
clear = do
    st <- get
    putReadLineStateDiff st
        { rlPosition = Position 0 0
        }

insertChar :: MonadTerminal m => Char -> StateT (ReadLineState m) m ()
insertChar c = do
    st <- get
    let insertAt :: Char -> Int -> String -> String
        insertAt x 0 ys     = x : ys
        insertAt x _ []     = []
        insertAt x i (y:ys) = y : insertAt x (i - 1) ys
    putReadLineStateDiff st
        { rlInputString = insertAt c (rlInputCursor st) (rlInputString st)
        , rlInputCursor = rlInputCursor st + 1
        }

delete ::  MonadTerminal m => StateT (ReadLineState m) m ()
delete = do
    st <- get
    let deleteAt _     [] = []
        deleteAt 0 (_:xs) = xs
        deleteAt i (x:xs) = x : deleteAt (i - 1) xs
    putReadLineStateDiff st
        { rlInputString = deleteAt (rlInputCursor st) (rlInputString st)
        } 

deleteBackward :: MonadTerminal m => StateT (ReadLineState m) m ()
deleteBackward = do
    st <- get
    let deleteAt _     [] = []
        deleteAt (-1) xs  = xs
        deleteAt 0 (_:xs) = xs
        deleteAt i (x:xs) = x : deleteAt (i - 1) xs 
    putReadLineStateDiff st
        { rlInputString = deleteAt (rlInputCursor st - 1) (rlInputString st)
        , rlInputCursor = max 0 (rlInputCursor st - 1)
        }

moveLeft :: MonadTerminal m => StateT (ReadLineState m) m ()
moveLeft = do
    st <- get
    putReadLineStateDiff st
        { rlInputCursor = max 0 (rlInputCursor st - 1)
        }

moveLeftWord :: MonadTerminal m => StateT (ReadLineState m) m ()
moveLeftWord = do
    st <- get
    let c = rlInputCursor st
        f _ l []         = l
        f i l (' ':x:xs)
            | i + 1 >= c = l
            | x /= ' '   = f (i + 2) (i + 1) xs
            | otherwise  = f (i + 2)  l      xs
        f i l (x:xs)
            | i >= c     = l
            | otherwise  = f (i + 1)  l      xs
    putReadLineStateDiff st
        { rlInputCursor = f 0 0 (rlInputString st)
        }

moveRight :: MonadTerminal m => StateT (ReadLineState m) m ()
moveRight = do
    st <- get
    putReadLineStateDiff st
        { rlInputCursor = min (rlInputCursor st + 1) (length (rlInputString st))
        }

moveRightWord :: MonadTerminal m => StateT (ReadLineState m) m ()
moveRightWord = do
    st <- get
    let c  = rlInputCursor st
        xs = rlInputString st
        f c [] = c
        f c (x:xs)
            | x == ' '  = g (c + 1) xs
            | otherwise = f (c + 1) xs
        g c [] = c
        g c (x:xs)
            | x == ' '  = g (c + 1) xs
            | otherwise = c
    putReadLineStateDiff st
        { rlInputCursor = f c (drop c xs)
        }

moveToLineBegin :: MonadTerminal m => StateT (ReadLineState m) m ()
moveToLineBegin = do
    st <- get
    putReadLineStateDiff st
        { rlInputCursor = 0
        }

moveToLineEnd :: MonadTerminal m => StateT (ReadLineState m) m ()
moveToLineEnd = do
    st <- get
    putReadLineStateDiff st
        { rlInputCursor = length (rlInputString st)
        }

---------------------------------------------------------------------------------------------------
-- POSITION CALCULATIONS
---------------------------------------------------------------------------------------------------

posPlus :: Size -> Position -> Int -> Position
posPlus size pos i = Position r c
    where
        (r,c) = quotRem (row pos * width size + col pos + i) (width size)

posPlusRows :: Size -> Position -> Int -> Position
posPlusRows size (Position r c) i =
    Position (r + i) c

posPlusText :: Size -> Position -> T.Text -> Position
posPlusText size pos t = posPlus size pos (T.length t)

posPlusDoc :: Size -> Position -> Doc ann -> Position
posPlusDoc size pos doc = posPlusSimpleDocStream size pos ds
    where 
        ds = layoutSmart defaultLayoutOptions doc

posPlusSimpleDocStream :: Size -> Position -> SimpleDocStream ann -> Position
posPlusSimpleDocStream size pos0 ds0 = f ds0 pos0
    where
        f SFail           p = p
        f SEmpty          p = p
        f (SChar _ ds)    p = f ds $! posPlus size p 1
        f (SText i _ ds)  p = f ds $! posPlus size p i
        f (SLine i ds)    p = f ds $! posPlus size (Position (row p + 1) (col p)) i
        f (SAnnPush _ ds) p = f ds p
        f (SAnnPop ds)    p = f ds p
