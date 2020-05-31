module TodoItem
( TodoItem
, parseTodoItem
, reverseForm
, toggleDone
) where

import Data.List.Extra
import Text.Regex.TDFA

data TodoItem = TodoItem
  { _original  :: String
  , _done      :: Bool
  , _priority  :: String
  , _dates     :: String
  , _desc      :: String
  , _project   :: [String]
  , _context   :: [String]
  , _keyval    :: [String]
  }

instance Show TodoItem where
    show item = do
        let x = if _done item then "x " else "  "
        let prio = if _priority item /= ""
                      then _priority item
                      else "    "
        " " ++ x
            ++ prio
            ++ _dates item
            ++ _desc item
            ++ printList (_project item)
            ++ printList (_context item)
            ++ printList (_keyval item)

reverseForm :: TodoItem -> String
reverseForm = _original

printList :: [String] -> String
printList [] = ""
printList [x] = " " ++ x
printList (x:xs) = " " ++ x ++ printList xs

parseTodoItem :: String -> TodoItem
parseTodoItem todoStr = do
    let doneResult = parseStart todoStr (getRegex "done")
        doneNext   = getNext doneResult
        prioResult = parseStart doneNext (getRegex "priority")
        prioNext   = getNext prioResult
        dateResult = parseStart prioNext (getRegex "date")
        dateNext   = getNext dateResult
        projects   = parseAll dateNext (getRegex "project")
        contexts   = parseAll dateNext (getRegex "context")
        keyvals    = parseAll dateNext (getRegex "keyval")
        varying    = merge projects $ merge contexts keyvals
    TodoItem { _original = todoStr
             , _done     = matched' doneResult /= ""
             , _priority = matched' prioResult
             , _dates    = matched' dateResult
             , _desc     = parseDesc dateNext varying
             , _project  = projects
             , _context  = contexts
             , _keyval   = keyvals
             }

toggleDone :: TodoItem -> TodoItem
toggleDone i = i { _original = if _done i
                                  then drop 2 $ _original i
                                  else 'x':' ': _original i
                 , _done = not $ _done i }

getRegex :: String -> String
getRegex "done" = "(x )"
getRegex "priority" = "(\\([A-Z]\\) )"
getRegex "date" = "([0-9]{4}-[0-9]{2}-[0-9]{2} ){1,2}"
getRegex "project" = "(^\\+[^ ]+ | \\+[^ ]+ | \\+[^ ]+$)"
getRegex "context" = "(^@[^ ]+ | @[^ ]+ | @[^ ]+$)"
getRegex "keyval" = "(^[^ :]+:[^ :]+ | [^ :]+:[^ :]+ | [^ :]+:[^ :]+$)"
getRegex _ = ""

parse :: String -> String -> (String, String, String)
parse str regex = str =~ regex

parseStart :: String -> String -> (String, String, String)
parseStart str regex = parse str ('^' : regex)

getNext :: (String, String, String) -> String
getNext (x,_,"") = x
getNext ("",_,z) = z
getNext t = error "Can't process " ++ show t

parseAll :: String -> String -> [String]
parseAll str regex = map trim $ getAllTextMatches (str =~ regex)

parseDesc :: String -> [String] -> String
parseDesc str varying = unwords $ (\\) (words str) varying

matched' :: (String, String, String) -> String
matched' (_,x,_) = x