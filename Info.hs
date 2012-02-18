{-# LANGUAGE CPP, Rank2Types, TupleSections #-}

module Info (infoExpr, typeExpr) where

import Cabal
import Control.Applicative
import CoreUtils
import Data.Function
import Data.Generics
import Data.List
import Data.Maybe
import Data.Ord as O
import Desugar
import GHC
import GHC.SYB.Utils
import GHCApi
import GHCChoice
import qualified Gap
import HscTypes
import NameSet
import Outputable
import PprTyThing
import Pretty (showDocWith, Mode(OneLineMode))
import System.Time
import TcRnTypes
import TcHsSyn (hsPatType)
import Types

----------------------------------------------------------------

type Expression = String
type ModuleString = String

----------------------------------------------------------------

infoExpr :: Options -> ModuleString -> Expression -> FilePath -> IO String
infoExpr opt modstr expr file = (++ "\n") <$> info opt file modstr expr

info :: Options -> FilePath -> ModuleString -> FilePath -> IO String
info opt fileName modstr expr =
    inModuleContext opt fileName modstr exprToInfo "Cannot show info"
  where
    exprToInfo = infoThing expr

----------------------------------------------------------------

typeExpr :: Options -> ModuleString -> Int -> Int -> FilePath -> IO String
typeExpr opt modstr lineNo colNo file = Info.typeOf opt file modstr lineNo colNo

typeOf :: Options -> FilePath -> ModuleString -> Int -> Int -> IO String
typeOf opt fileName modstr lineNo colNo =
    inModuleContext opt fileName modstr exprToType errmsg
  where
    exprToType = do
      modSum <- getModSummary $ mkModuleName modstr
      p <- parseModule modSum
      tcm <- typecheckModule p
      let es = findExpr tcm lineNo colNo
      ets <- catMaybes <$> mapM (getExprType tcm) es
      let bs = findBind tcm lineNo colNo
          bts = catMaybes $ map getBindType bs
      let ps = findPat tcm lineNo colNo
          pts = map getPatType ps
      let sss = map toTup $ sortBy (cmp `on` fst) $ concat [ets, bts, pts]
      return $ convert opt sss

    toTup :: (SrcSpan, Type) -> ((Int,Int,Int,Int),String)
    toTup (spn, typ) = (fourInts spn, pretty typ)

    fourInts :: SrcSpan -> (Int,Int,Int,Int)
    fourInts = fromMaybe (0,0,0,0) . Gap.getSrcSpan

    cmp a b
      | a `isSubspanOf` b = O.LT
      | b `isSubspanOf` a = O.GT
      | otherwise = O.EQ

    errmsg = convert opt ([] :: [((Int,Int,Int,Int),String)])

findExpr :: TypecheckedModule -> Int -> Int -> [LHsExpr Id]
findExpr tcm line col =
    let src = tm_typechecked_source tcm
    in listifyStaged TypeChecker f src
  where
    f :: LHsExpr Id -> Bool
    f (L spn _) = isGoodSrcSpan spn && spn `spans` (line, col)

findBind :: TypecheckedModule -> Int -> Int -> [LHsBind Id]
findBind TypecheckedModule{tm_typechecked_source = src} line col = listifyStaged TypeChecker f src
  where
    f :: LHsBind Id -> Bool
    f (L _ (FunBind{fun_id = L spn _})) = isGoodSrcSpan spn && spn `spans` (line, col)
    f _ = False

findPat :: TypecheckedModule -> Int -> Int -> [LPat Id]
findPat TypecheckedModule{tm_typechecked_source = src} line col = listifyStaged TypeChecker f src
  where
    f :: LPat Id -> Bool
    f (L spn _) = isGoodSrcSpan spn && spn `spans` (line, col)

listifyStaged :: Typeable r => Stage -> (r -> Bool) -> GenericQ [r]
listifyStaged s p = everythingStaged s (++) [] ([] `mkQ` (\x -> [x | p x]))

getExprType :: GhcMonad m => TypecheckedModule -> LHsExpr Id -> m (Maybe (SrcSpan, Type))
getExprType tcm e = do
    hs_env <- getSession
    (_, mbe) <- Gap.liftIO $ deSugarExpr hs_env modu rn_env ty_env e
    return $ (getLoc e, ) <$> CoreUtils.exprType <$> mbe
  where
    modu = ms_mod $ pm_mod_summary $ tm_parsed_module tcm
    rn_env = tcg_rdr_env $ fst $ tm_internals_ tcm
    ty_env = tcg_type_env $ fst $ tm_internals_ tcm

getBindType :: LHsBind Id -> Maybe (SrcSpan, Type)
getBindType (L _ FunBind{fun_id = L spn _, fun_matches = MatchGroup _ typ}) = Just (spn, typ)
getBindType _ = Nothing

getPatType :: LPat Id -> (SrcSpan, Type)
getPatType (L spn pat) = (spn, hsPatType pat)

pretty :: Type -> String
pretty = showDocWith OneLineMode . withPprStyleDoc (mkUserStyle neverQualify AllTheWay) . pprTypeForUser False

----------------------------------------------------------------
-- from ghc/InteractiveUI.hs

infoThing :: String -> Ghc String
infoThing str = do
    names <- parseName str
    mb_stuffs <- mapM getInfo names
    let filtered = filterOutChildren (\(t,_f,_i) -> t) (catMaybes mb_stuffs)
    unqual <- getPrintUnqual
    return $ showSDocForUser unqual $ vcat (intersperse (text "") $ map (pprInfo False) filtered)

filterOutChildren :: (a -> TyThing) -> [a] -> [a]
filterOutChildren get_thing xs
  = [x | x <- xs, not (getName (get_thing x) `elemNameSet` implicits)]
  where
      implicits = mkNameSet [getName t | x <- xs, t <- implicitTyThings (get_thing x)]

pprInfo :: PrintExplicitForalls -> (TyThing, GHC.Fixity, [Instance]) -> SDoc
pprInfo pefas (thing, fixity, insts)
    = pprTyThingInContextLoc pefas thing
   $$ show_fixity fixity
   $$ vcat (map pprInstance insts)
  where
    show_fixity fx
        | fx == defaultFixity = Outputable.empty
        | otherwise           = ppr fx <+> ppr (getName thing)

----------------------------------------------------------------

inModuleContext :: Options -> FilePath -> ModuleString -> Ghc String -> String -> IO String
inModuleContext opt fileName modstr action errmsg =
    withGHC (valid ||> invalid ||> return errmsg)
  where
    valid = do
        (file,_) <- initializeGHC opt fileName ["-w"] False
        setTargetFile file
        load LoadAllTargets
        doif setContextFromTarget action
    invalid = do
        initializeGHC opt fileName ["-w"] False
        setTargetBuffer
        load LoadAllTargets
        doif setContextFromTarget action
    setTargetBuffer = do
        modgraph <- depanal [mkModuleName modstr] True
        let imports = concatMap (map (showSDoc . ppr . unLoc)) $
                      map ms_imps modgraph ++ map ms_srcimps modgraph
            moddef = "module " ++ sanitize modstr ++ " where"
            header = moddef : imports
        importsBuf <- Gap.toStringBuffer header
        clkTime <- Gap.liftIO getClockTime
        setTargets [Target (TargetModule $ mkModuleName modstr) True (Just (importsBuf, clkTime))]
    doif m t = m >>= \ok -> if ok then t else goNext
    sanitize = fromMaybe "SomeModule" . listToMaybe . words

setContextFromTarget :: Ghc Bool
setContextFromTarget = depanal [] False >>= Gap.setCtx
