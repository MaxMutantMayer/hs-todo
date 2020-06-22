{-# LANGUAGE TemplateHaskell #-}

module TodoUI
( runMain
) where

import Brick.Util (on)
import Brick.Widgets.Core (fill, hLimitPercent, str, vBox, vLimit, (<+>))
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Data.Char
import Data.Ord
import Data.Text.Zipper
import Lens.Micro
import Lens.Micro.TH
import Text.Printf

import qualified Brick.AttrMap                as BA
import qualified Brick.Focus                  as BF
import qualified Brick.Widgets.List           as BL
import qualified Brick.Main                   as BM
import qualified Brick.Widgets.Edit           as BE
import qualified Brick.Types                  as BT
import qualified Data.Vector                  as Vec
import qualified Data.Vector.Algorithms.Intro as VecA
import qualified Graphics.Vty                 as V
import qualified TodoIO                       as IO
import qualified TodoItem                     as TI

-- Types

data Name
    = List
    | Edit
    deriving (Eq, Ord, Show)

data EditMode
    = None
    | AddNew
    | EditEntry
    | SearchEntry
    | ExitPrompt
    deriving (Eq, Ord, Show)

data St = St
    { _file :: String
    , _focusRing :: BF.FocusRing Name
    , _list :: BL.List Name TI.TodoItem
    , _label :: String
    , _edit :: BE.Editor String Name
    , _editMode :: EditMode
    , _nextId :: Integer
    }
makeLenses ''St

-- Texts

txtHeader, txtSave, txtNoSel, txtAdd, txtEdit, txtDel, txtErrEmpty :: String
txtHeader = "hs-todo 0.0.1 - Your tasks (%s of %s)"
txtSave = "\"%s\" written"
txtNoSel = "No item selected!"
txtAdd = "Successfully added new item"
txtEdit = "Successfully updated item"
txtDel = "Deleted selected item"
txtErrEmpty = "Can't use empty input!"

txtLabel :: EditMode -> String
txtLabel AddNew = "Add"
txtLabel EditEntry = "Edit"
txtLabel SearchEntry = "Search"
txtLabel ExitPrompt = "There are unsaved changes. Save them? [Yy]es [Nn]o [Cc]ancel"
txtLabel _ = ""

-- Drawing

drawUI :: St -> [BT.Widget Name]
drawUI st = [ui]
    where
        f = st^.focusRing
        l = st^.list
        e = st^.edit
        la = if null (st^.label)
                then str ""
                else str (st^.label) <+> str ": "
        cur = case l^.BL.listSelectedL of
                Nothing -> "-"
                Just i  -> show (i + 1)
        total = show $ Vec.length $ l^.BL.listElementsL
        header = str $ printf txtHeader cur total
        footer = la <+> BF.withFocusRing f (BE.renderEditor (str. unlines)) e
        ui = vBox [ header
                  , BF.withFocusRing f (BL.renderList listDrawElement) l
                  , footer
                  ]

listDrawElement :: Bool -> TI.TodoItem -> BT.Widget Name
listDrawElement _ l = limit $ str (TI.printIndented l) <+> fill ' '
    where limit = hLimitPercent 100 . vLimit 1

-- Sorting

applySort
    :: (Vec.Vector TI.TodoItem -> Vec.Vector TI.TodoItem)
    -> St
    -> St
applySort f st = do
    let l = st^.list
        sorted = l & BL.listElementsL %~ f
    st & list .~ case BL.listSelectedElement l of
                   Nothing -> sorted
                   Just (_, i) -> BL.listMoveToElement i sorted

sortBy
    :: (Ord b)
    => (TI.TodoItem -> b)
    -> Vec.Vector TI.TodoItem
    -> Vec.Vector TI.TodoItem
sortBy f = Vec.modify $ VecA.sortBy $ comparing f

sortOrig, sortId, sortDone, sortDate, sortPrio, sortProj, sortCont
    :: Vec.Vector TI.TodoItem
    -> Vec.Vector TI.TodoItem
sortOrig = sortBy TI._original
sortId   = sortBy TI._id
sortDone = sortBy TI._done
sortDate = sortBy TI._dates
sortPrio = sortBy TI._priority
sortProj = sortBy TI._project
sortCont = sortBy TI._context

unsort :: St -> St
unsort = applySort sortId

resort
    :: (Vec.Vector TI.TodoItem -> Vec.Vector TI.TodoItem)
    -> St
    -> St
resort f = applySort f . unsort

unsortedItems :: St -> [TI.TodoItem]
unsortedItems st = Vec.toList $ ust ^. (list . BL.listElementsL)
    where ust = unsort st

-- Handling events

appHandleEvent :: St -> BT.BrickEvent Name e -> BT.EventM Name (BT.Next St)
appHandleEvent st (BT.VtyEvent e) =
    case BF.focusGetCurrent (st^.focusRing) of
      Just List -> case e of
            V.EvKey V.KEsc [] -> onExit st
            V.EvKey (V.KChar 'q') [] -> onExit st
            V.EvKey (V.KChar 'w') [] -> BM.continue =<< liftIO (handleWriteFile st)
            V.EvKey (V.KChar '/') [] -> BM.continue $ enterEdit st SearchEntry
            V.EvKey (V.KChar ' ') [] -> BM.continue $ st & list %~ BL.listModify TI.toggleDone
            V.EvKey (V.KChar 'n') [] -> BM.continue $ enterEdit st AddNew
            V.EvKey (V.KChar 'x') [] -> BM.continue $ deleteEntry st
            V.EvKey (V.KChar 'e') [] -> BM.continue $ editCurrent st
            V.EvKey (V.KChar 's') [] -> BM.continue $ resort sortOrig st
            V.EvKey (V.KChar '1') [] -> BM.continue $ resort sortDone st
            V.EvKey (V.KChar '2') [] -> BM.continue $ resort sortDate st
            V.EvKey (V.KChar '3') [] -> BM.continue $ resort sortPrio st
            V.EvKey (V.KChar '4') [] -> BM.continue $ resort sortProj st
            V.EvKey (V.KChar '5') [] -> BM.continue $ resort sortCont st
            V.EvKey (V.KChar '=') [] -> BM.continue $ unsort st
            _ -> BM.continue =<< BT.handleEventLensed st list (BL.handleListEventVi BL.handleListEvent) e
      Just Edit -> case e of
            V.EvKey V.KEsc []   -> BM.continue . clearEdit $ leaveEdit st
            V.EvKey V.KEnter [] -> handleEditInput st
            _ -> BM.continue =<< BT.handleEventLensed st edit BE.handleEditorEvent e
      Nothing -> BM.continue st
appHandleEvent st _ = BM.continue st

onExit :: St -> BT.EventM Name (BT.Next St)
onExit st = do
    let current = unsortedItems st
    savedItems <- liftIO (IO.readTodoFile (st^.file))
    if current /= savedItems
       then BM.continue $ enterEdit st ExitPrompt
       else BM.halt st

handleWriteFile :: St -> IO St
handleWriteFile st = do
    let path = st^.file
        items = unsortedItems st
        msg = printf txtSave (st^.file)
    IO.writeTodoFile path items
    return $ setEditText msg st

enterEdit :: St -> EditMode -> St
enterEdit st m = st & clearEdit
                    & focusRing %~ BF.focusSetCurrent Edit
                    & editMode .~ m
                    & label .~ txtLabel m

setEditText :: String -> St -> St
setEditText s st = st & clearEdit & edit %~ BE.applyEdit (insertMany s)

handleEditInput :: St -> BT.EventM Name (BT.Next St)
handleEditInput st =
    case st^.editMode of
      AddNew     -> BM.continue . leaveEdit $ addNewEntry st
      EditEntry  -> BM.continue . leaveEdit $ updateCurrentEntry st
      ExitPrompt -> handleUnsavedChanges st
      _          -> BM.continue st

handleUnsavedChanges :: St -> BT.EventM Name (BT.Next St)
handleUnsavedChanges st
    | s == "y" || s == "yes" = BM.halt =<< liftIO (handleWriteFile st)
    | s == "n" || s == "no"  = BM.halt st
    | otherwise              = BM.continue . clearEdit $ leaveEdit st
    where input = BE.getEditContents (st^.edit)
          s     = if null input then "" else map toLower $ head input

addNewEntry :: St -> St
addNewEntry st =
    case parseValidInput $ BE.getEditContents (st^.edit) of
      Left err       -> setEditText err st
      Right todoItem -> do
          let pos = getNextPostion st
              i = todoItem { TI._id = st^.nextId }
          setEditText txtAdd $ st & list %~ BL.listInsert pos i
                                  & nextId %~ (+1)

parseValidInput :: [String] -> Either String TI.TodoItem
parseValidInput input =
    if null input || null (head input)
       then Left txtErrEmpty
       else TI.parseTodoItem $ head input

getNextPostion :: St -> Int
getNextPostion st = Vec.length $ st ^. (list . BL.listElementsL)

updateCurrentEntry :: St -> St
updateCurrentEntry st =
    case parseValidInput $ BE.getEditContents (st^.edit) of
      Left err       -> setEditText err st
      Right todoItem -> setEditText txtEdit $ st & list %~ BL.listModify (replaceWith todoItem)

replaceWith :: TI.TodoItem -> TI.TodoItem -> TI.TodoItem
replaceWith i _ = i

deleteEntry :: St -> St
deleteEntry st =
    case st ^. (list . BL.listSelectedL) of
      Nothing -> setEditText txtNoSel st
      Just i  -> setEditText txtDel $ st & list %~ BL.listRemove i

editCurrent :: St -> St
editCurrent st =
    case BL.listSelectedElement (st^.list) of
      Nothing        -> setEditText txtNoSel st
      Just (_, item) -> setEditText (show item) $ enterEdit st EditEntry

clearEdit :: St -> St
clearEdit st = st & edit %~ BE.applyEdit clearZipper

leaveEdit :: St -> St
leaveEdit st = st & focusRing %~ BF.focusSetCurrent List
                  & editMode .~ None
                  & label .~ ""

-- Attributes

appAttrMap :: BA.AttrMap
appAttrMap = BA.attrMap V.defAttr
    [ (BL.listAttr,            V.white `on` V.black)
    , (BL.listSelectedAttr,    V.black `on` V.yellow)
    ]

-- App definition

todoApp :: BM.App St e Name
todoApp = BM.App { BM.appDraw = drawUI
                 , BM.appChooseCursor = BM.showFirstCursor
                 , BM.appHandleEvent = appHandleEvent
                 , BM.appStartEvent = return
                 , BM.appAttrMap = const appAttrMap
                 }

initialState :: String -> [TI.TodoItem] -> St
initialState path todoItems =
    St path
       (BF.focusRing [List, Edit])
       (BL.list List (Vec.fromList todoItems) 1)
       ""
       (BE.editor Edit (Just 1) "")
       None
       (toInteger $ length todoItems + 1)

-- Start brick app

runMain :: String -> [TI.TodoItem] -> IO ()
runMain path entries = void $ BM.defaultMain todoApp (initialState path entries)
