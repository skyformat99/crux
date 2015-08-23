{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TupleSections     #-}

module Crux.Typecheck where

import Crux.Prelude
import Control.Exception (throwIO, ErrorCall(..))
import           Crux.AST
import           Crux.Intrinsic        (Intrinsic (..))
import qualified Crux.Intrinsic        as Intrinsic
import qualified Crux.MutableHashTable as HashTable
import           Crux.Text             (isCapitalized)
import           Crux.Tokens           (Pos (..))
import qualified Data.HashMap.Strict   as HashMap
import           Data.List             (intercalate, nub, sort)
import qualified Data.Text             as Text
import           Prelude               hiding (String)
import           Text.Printf           (printf)

copyIORef :: IORef a -> IO (IORef a)
copyIORef ior = do
    v <- readIORef ior
    newIORef v

data Env = Env
    { eNextTypeIndex :: IORef Int
    , eBindings      :: IORef (HashMap Text TypeVar)
    , eTypeBindings  :: HashMap Text TypeVar
    , eTypeAliases   :: HashMap Text TypeAlias
    , eReturnType    :: Maybe TypeVar -- Nothing if top-level expression
    }

showTypeVarIO :: TypeVar -> IO [Char]
showTypeVarIO tvar = do
  tvar' <- readIORef tvar
  case tvar' of
    TVar i o' -> do
        os <- case o' of
            Unbound j -> return $ "Unbound " ++ show j
            Link x -> showTypeVarIO x
        return $ "(TVar " ++ show i ++ " " ++ os ++ ")"
    TQuant i ->
        return $ "TQuant " ++ show i
    TFun arg ret -> do
        as <- mapM showTypeVarIO arg
        rs <- showTypeVarIO ret
        return $ "TFun (" ++ intercalate "," as ++ ") -> " ++ rs
    TUserType def tvars -> do
        tvs <- mapM showTypeVarIO tvars
        return $ (Text.unpack $ tuName def) ++ " " ++ (intercalate " " tvs)
    TRecord (RecordType open' rows') -> do
        let rowNames = map fst rows'
        rowTypes <- mapM (showTypeVarIO . snd) rows'
        let showRow (name, ty) = Text.unpack name <> ": " <> ty
        let dotdotdot = case open' of
                RecordFree -> ["f..."]
                RecordQuantified -> ["q..."]
                RecordClose -> []
        return $ "{" <> (intercalate "," (map showRow (zip rowNames rowTypes) <> dotdotdot)) <> "}"
    TPrimitive ty ->
        return $ show ty

newEnv :: Maybe TypeVar -> IO Env
newEnv eReturnType = do
    eNextTypeIndex <- newIORef 0
    eBindings <- newIORef HashMap.empty
    let eTypeBindings = HashMap.empty
        eTypeAliases = HashMap.empty
    return Env {..}

childEnv :: Env -> IO Env
childEnv env = do
    bindings' <- HashTable.clone (eBindings env)
    return env{eBindings=bindings'}

freshType :: Env -> IO TypeVar
freshType Env{eNextTypeIndex} = do
    modifyIORef' eNextTypeIndex (+1)
    index <- readIORef eNextTypeIndex
    newIORef $ TVar index (Unbound index)

typeFromConstructor :: Env -> Name -> IO (Maybe (TypeVar, TVariant TypeVar))
typeFromConstructor env cname = do
    let fold acc ty = case (acc, ty) of
            (Just a, _) -> return $ Just a
            (Nothing, ut) -> do
                ut' <- readIORef ut
                case ut' of
                    TUserType def _ -> do
                        let TUserTypeDef { tuVariants = variants } = def
                        case [v | v@(TVariant vname _) <- variants, vname == cname] of
                            [v] -> return $ Just (ut, v)
                            [] -> return Nothing
                            _ -> error "This should never happen: Type has multiple variants with the same constructor name"
                    _ ->
                        return Nothing
    foldlM fold Nothing (HashMap.elems $ eTypeBindings env)

-- | Build up an environment for a case of a match block.
-- exprType is the type of the expression.  We unify this with the constructor of the pattern
buildPatternEnv :: TypeVar -> Env -> Pattern -> IO ()
buildPatternEnv exprType env patt = case patt of
    PPlaceholder pname -> do
        HashTable.insert pname exprType (eBindings env)

    PConstructor cname cargs -> do
        ctor <- typeFromConstructor env cname
        case ctor of
            Just (ctorTy, _) -> do
                t <- readIORef ctorTy
                case t of
                    TUserType def tyVars -> do
                        subst <- HashTable.new
                        (ty', variants) <- instantiateUserType subst env def tyVars
                        unify exprType ty'

                        let findVariant [] = error "findVariant: This should never happen"
                            findVariant (v:rest)
                                | tvName v == cname = Just v
                                | otherwise = findVariant rest

                        let Just variant = findVariant variants
                        let TVariant{tvParameters} = variant

                        when (length tvParameters /= length cargs) $
                            error $ printf "Pattern should specify %i args but got %i" (length tvParameters) (length cargs)

                        forM_ (zip cargs tvParameters) $ \(arg, vp) -> do
                            buildPatternEnv vp env arg
                    _ -> error "buildPatternEnv: Pattern for non-sum type??  This should never happen."
            _ -> error $ printf "Unbound constructor %s" (show cname)

check :: Env -> Expression Pos -> IO (Expression TypeVar)
check env expr = case expr of
    EFun _ params body -> do
        bindings' <- HashTable.clone (eBindings env)
        paramTypes <- forM params $ \p -> do
            pt <- freshType env
            HashTable.insert p pt bindings'
            return pt

        returnType <- freshType env

        let env' = env{eBindings=bindings', eReturnType=Just returnType}
        body' <- check env' body
        unify returnType $ edata body'
        ty <- newIORef $ TFun paramTypes returnType
        return $ EFun ty params body'

    EApp _ (EIdentifier _ "_unsafe_js") [ELiteral _ (LString txt)] -> do
        t <- freshType env
        return $ EIntrinsic t (IUnsafeJs txt)
    EApp _ (EIdentifier _ "_unsafe_js") _ ->
        error "_unsafe_js takes just one string literal"

    EApp _ (EIdentifier _ "_unsafe_coerce") [subExpr] -> do
        t <- freshType env
        subExpr' <- check env subExpr
        return $ EIntrinsic t (IUnsafeCoerce subExpr')
    EApp _ (EIdentifier _ "_unsafe_coerce") _ ->
        error "_unsafe_coerce takes just one argument"

    EApp _ (EIdentifier _ "print") args -> do
        args' <- mapM (check env) args
        ty <- newIORef $ TPrimitive Unit
        return $ EIntrinsic ty (IPrint args')

    EApp _ (EIdentifier _ "toString") [arg] -> do
        arg' <- check env arg
        ty <- newIORef $ TPrimitive String
        return $ EIntrinsic ty (IToString arg')

    EApp _ (EIdentifier _ "toString") _ ->
        error "toString takes just one argument"

    EApp _ lhs rhs -> do
        lhs' <- check env lhs
        rhs' <- mapM (check env) rhs
        result <- freshType env
        ty <- newIORef $ TFun (map edata rhs') result
        unify (edata lhs') ty
        return $ EApp result lhs' rhs'

    EIntrinsic {} -> do
        error "Unexpected: EIntrinsic encountered during typechecking"

    ERecordLiteral _ fields -> do
        fields' <- forM (HashMap.toList fields) $ \(name, fieldExpr) -> do
            ty <- freshType env
            fieldExpr' <- check env fieldExpr
            unify ty (edata fieldExpr')
            return (name, fieldExpr')

        let fieldTypes = map (\(name, ex) -> (name, edata ex)) fields'

        recordTy <- newIORef $ TRecord $ RecordType RecordClose fieldTypes
        return $ ERecordLiteral recordTy (HashMap.fromList fields')

    ELookup _ lhs propName -> do
        lhs' <- check env lhs
        ty <- freshType env
        recTy <- newIORef $ TRecord $ RecordType RecordFree [(propName, ty)]
        unify (edata lhs') recTy
        return $ ELookup ty lhs' propName

    EMatch _ matchExpr cases -> do
        resultType <- freshType env

        matchExpr' <- check env matchExpr

        cases' <- forM cases $ \(Case patt caseExpr) -> do
            env' <- childEnv env
            buildPatternEnv (edata matchExpr') env' patt
            caseExpr' <- check env' caseExpr
            unify resultType (edata caseExpr')
            return $ Case patt caseExpr'

        return $ EMatch resultType matchExpr' cases'

    ELet _ mut name maybeAnnot expr' -> do
        ty <- freshType env
        expr'' <- check env expr'
        HashTable.insert name ty (eBindings env)
        unify ty (edata expr'')
        forM_ maybeAnnot $ \annotation -> do
            annotTy <- resolveTypeIdent env [] annotation
            unify ty annotTy

        unitTy <- newIORef $ TPrimitive Unit
        return $ ELet unitTy mut name maybeAnnot expr''

    ELiteral _ lit -> do
        litType <- newIORef $ case lit of
                LInteger _ -> TPrimitive Number
                LString _ -> TPrimitive String
                LUnit -> TPrimitive Unit
        return $ ELiteral litType lit
    EIdentifier _ "print" ->
        error "Intrinsic print is not a value"
    EIdentifier _ "toString" ->
        error "Intrinsic toString is not a value"
    EIdentifier _ "_unsafe_js" ->
        error "Intrinsic _unsafe_js is not a value"
    EIdentifier _ "_unsafe_coerce" ->
        error "Intrinsic _unsafe_coerce is not a value"
    EIdentifier pos txt -> do
        result <- HashTable.lookup txt (eBindings env)
        case result of
            Nothing -> do
                error $ "Unbound symbol " ++ show (pos, txt)
            Just tyref -> do
                tyref' <- instantiate env tyref
                return $ EIdentifier tyref' txt
    ESemi _ lhs rhs -> do
        lhs' <- check env lhs
        rhs' <- check env rhs
        return $ ESemi (edata rhs') lhs' rhs'

    -- TEMP: For now, all binary intrinsics are Number -> Number -> Number
    EBinIntrinsic _ bi lhs rhs -> do
        numTy <- newIORef $ TPrimitive Number

        lhs' <- check env lhs
        unify numTy (edata lhs')

        rhs' <- check env rhs
        unify numTy (edata rhs')

        return $ EBinIntrinsic numTy bi lhs' rhs'

    EIfThenElse _ condition ifTrue ifFalse -> do
        booleanType <- case HashMap.lookup "Boolean" $ eTypeBindings env of
            Just t -> return t
            Nothing -> throwIO $ ErrorCall "FATAL: Environment does not contain a Boolean type"

        condition' <- check env condition
        unify booleanType (edata condition')
        ifTrue' <- check env ifTrue
        ifFalse' <- check env ifFalse

        unify (edata ifTrue') (edata ifFalse')

        return $ EIfThenElse (edata ifTrue') condition' ifTrue' ifFalse'

    EReturn _ rv -> do
        rv' <- check env rv
        case eReturnType env of
            Nothing ->
                error "Cannot return outside of functions"
            Just rt -> do
                unify rt $ edata rv'
                return $ EReturn (edata rv') rv'

quantify :: TypeVar -> IO ()
quantify ty = do
    ty' <- readIORef ty
    case ty' of
        TVar i tv' -> do
            case tv' of
                Unbound j -> do
                    qTy <- newIORef $ TQuant j
                    writeIORef ty (TVar i $ Link qTy)
                Link t' ->
                    quantify t'
        TFun param ret -> do
            mapM_ quantify param
            quantify ret
        TRecord (RecordType open rows') -> do
            forM_ rows' $ \(_key, val) -> do
                quantify val
            let open' = case open of
                    RecordFree -> RecordQuantified
                    _ -> open
            writeIORef ty $ TRecord $ RecordType open' rows'
        _ ->
            return ()

instantiateUserType :: IORef (HashMap Int TypeVar) -> Env -> TUserTypeDef TypeVar -> [TypeVar] -> IO (TypeVar, [TVariant TypeVar])
instantiateUserType subst env def tyVars = do
    typeVars' <- mapM (instantiate' subst env) tyVars
    let typeVars'' = if and (map fst typeVars')
            then map snd typeVars'
            else tyVars
    userType <- newIORef $ TUserType def typeVars''
    variants <- forM (tuVariants def) $ \variant -> do
        paramTypes <- forM (tvParameters variant) $ \param -> do
            instantiate' subst env param
        return variant{tvParameters=map snd paramTypes}
    return (userType, variants)

instantiate' :: IORef (HashMap Int TypeVar) -> Crux.Typecheck.Env -> TypeVar -> IO (Bool, TypeVar)
instantiate' subst env ty = do
    ty' <- readIORef ty
    case ty' of
        TQuant name -> do
            mv <- HashTable.lookup name subst
            case mv of
                Just v ->
                    return (True, v)
                Nothing -> do
                    tv <- freshType env
                    HashTable.insert name tv subst
                    return (True, tv)
        TVar _ vl -> do
            case vl of
                Link tv'  -> instantiate' subst env tv'
                Unbound _ -> return (False, ty)
        TFun param ret -> do
            ty1 <- mapM (instantiate' subst env) param
            (b2, ty2) <- instantiate' subst env ret
            let b = b2 || and (map fst ty1)
            tfun <- newIORef $ TFun (map snd ty1) ty2
            return (b, tfun)
        TUserType def tyVars -> do
            typeVars' <- mapM (instantiate' subst env) tyVars
            tut <- newIORef $ TUserType def (map snd typeVars')
            return (and (map fst typeVars'), tut)
        TRecord (RecordType open rows) -> do
            rows' <- forM rows $ \(name, rowTy) -> do
                (b, rowTy') <- instantiate' subst env rowTy
                return (b, (name, rowTy'))

            let (changedOpen, open') = case open of
                    RecordQuantified -> (True, RecordFree)
                    _ -> (False, open)
            tr <- newIORef $ TRecord $ RecordType open' (map snd rows')
            return (changedOpen || or (map fst rows'), tr)
        TPrimitive {} -> return (False, ty)

instantiate :: Env -> TypeVar -> IO TypeVar
instantiate env t = do
    subst <- HashTable.new
    (didAnything, t') <- instantiate' subst env t
    return $ if didAnything
        then t'
        else t

flattenTypeDef :: TUserTypeDef TypeVar -> IO (TUserTypeDef ImmutableTypeVar)
flattenTypeDef TUserTypeDef{..} = do
    parameters' <- mapM flattenTypeVar tuParameters
    -- Huge hack: don't try to flatten variants because they can be recursive
    let variants' = []
    let td = TUserTypeDef {tuName, tuParameters=parameters', tuVariants=variants'}
    return td

flattenTypeVar :: TypeVar -> IO ImmutableTypeVar
flattenTypeVar tv = do
    tv' <- readIORef tv
    case tv' of
        TVar i t -> do
            case t of
                Unbound j ->
                    return $ IVar i (Unbound j)
                Link tv'' -> do
                    flattenTypeVar tv''
        TQuant i ->
            return $ IQuant i
        TFun arg body -> do
            arg' <- mapM flattenTypeVar arg
            body' <- flattenTypeVar body
            return $ IFun arg' body'
        TUserType def tvars -> do
            tvars' <- mapM flattenTypeVar tvars
            def' <- flattenTypeDef def
            return $ IUserType def' tvars'
        TRecord (RecordType open' rows') -> do
            let flattenRow (name, ty) = do
                    ty' <- flattenTypeVar ty
                    return (name, ty')
            rows'' <- mapM flattenRow rows'
            return $ IRecord $ RecordType open' rows''
        TPrimitive t ->
            return $ IType t

flattenIntrinsic :: IntrinsicId TypeVar -> IO (IntrinsicId ImmutableTypeVar)
flattenIntrinsic = mapIntrinsicInputs flatten

flatten :: Expression TypeVar -> IO (Expression ImmutableTypeVar)
flatten expr = case expr of
    EFun td params body -> do
        td' <- flattenTypeVar td
        body' <- flatten body
        return $ EFun td' params body'
    EApp td lhs rhs -> do
        td' <- flattenTypeVar td
        lhs' <- flatten lhs
        rhs' <- mapM flatten rhs
        return $ EApp td' lhs' rhs'
    EIntrinsic td intrin -> do
        td' <- flattenTypeVar td
        intrin' <- flattenIntrinsic intrin
        return $ EIntrinsic td' intrin'
    ERecordLiteral td fields -> do
        td' <- flattenTypeVar td
        fields' <- forM (HashMap.toList fields) $ \(name, fieldExpr) -> do
            fieldExpr' <- flatten fieldExpr
            return (name, fieldExpr')

        return $ ERecordLiteral td' (HashMap.fromList fields')
    ELookup td lhs rhs -> do
        td' <- flattenTypeVar td
        lhs' <- flatten lhs
        return $ ELookup td' lhs' rhs
    EMatch td matchExpr cases -> do
        td' <- flattenTypeVar td
        expr' <- flatten matchExpr
        cases' <- forM cases $ \(Case pattern subExpr) ->
            fmap (Case pattern) (flatten subExpr)
        return $ EMatch td' expr' cases'
    ELet td mut name typeAnn expr' -> do
        td' <- flattenTypeVar td
        expr'' <- flatten expr'
        return $ ELet td' mut name typeAnn expr''
    ELiteral td lit -> do
        td' <- flattenTypeVar td
        return $ ELiteral td' lit
    EIdentifier td i -> do
        td' <- flattenTypeVar td
        return $ EIdentifier td' i
    ESemi td lhs rhs -> do
        td' <- flattenTypeVar td
        lhs' <- flatten lhs
        rhs' <- flatten rhs
        return $ ESemi td' lhs' rhs'
    EBinIntrinsic td name lhs rhs -> do
        td' <- flattenTypeVar td
        lhs' <- flatten lhs
        rhs' <- flatten rhs
        return $ EBinIntrinsic td' name lhs' rhs'
    EIfThenElse td condition ifTrue ifFalse -> do
        td' <- flattenTypeVar td
        condition' <- flatten condition
        ifTrue' <- flatten ifTrue
        ifFalse' <- flatten ifFalse
        return $ EIfThenElse td' condition' ifTrue' ifFalse'
    EReturn td rv -> do
        td' <- flattenTypeVar td
        rv' <- flatten rv
        return $ EReturn td' rv'

flattenDecl :: Declaration TypeVar -> IO (Declaration ImmutableTypeVar)
flattenDecl (Declaration export decl) = fmap (Declaration export) $ case decl of
    DData name typeVars variants ->
        return $ DData name typeVars variants
    DJSData name variants ->
        return $ DJSData name variants
    DType (TypeAlias name typeVars ident) ->
        return $ DType $ TypeAlias name typeVars ident
    DLet ty mut name typeAnn expr -> do
        ty' <- flattenTypeVar ty
        expr' <- flatten expr
        return $ DLet ty' mut name typeAnn expr'
    DFun (FunDef ty name params body) -> do
        ty' <- flattenTypeVar ty
        body' <- flatten body
        return $ DFun $ FunDef ty' name params body'

flattenModule :: Module a TypeVar -> IO (Module a ImmutableTypeVar)
flattenModule Module{..} = do
    decls <- mapM flattenDecl mDecls
    return $ Module
        { mImports=mImports
        , mDecls=decls
        }

unificationError :: [Char] -> TypeVar -> TypeVar -> IO a
unificationError message a b = do
    sa <- showTypeVarIO a
    sb <- showTypeVarIO b
    error $ "Unification error: " ++ message ++ " " ++ sa ++ " and " ++ sb

unify :: TypeVar -> TypeVar -> IO ()
unify av bv = do
  a <- readIORef av
  b <- readIORef bv

  case (a, b) of
    (TVar aid _, TVar bid _)
        | aid == bid ->
            return ()
    (TVar i a', _) -> do
        case a' of
            Unbound _ -> do
                occurs a' bv
                writeIORef av (TVar i $ Link bv)
            Link a'' ->
                unify a'' bv

    (_, TVar {}) -> do
        unify bv av

    (TPrimitive aType, TPrimitive bType)
        | aType == bType ->
            return ()
        | otherwise -> do
            unificationError "" av bv

    (TUserType ad atv, TUserType bd btv)
        | tuName ad == tuName bd -> do
            mapM_ (uncurry unify) (zip atv btv)
        | otherwise -> do
            unificationError "" av bv

    (TRecord {}, TRecord {}) ->
        unifyRecord av bv

    (TFun aa ar, TFun ba br) -> do
        when (length aa /= length ba) $
            unificationError "" av bv

        mapM_ (uncurry unify) (zip aa ba)
        unify ar br

    (TFun {}, TPrimitive {}) ->
        unificationError "" av bv
    (TPrimitive {}, TFun {}) ->
        unificationError "" av bv

    -- These should never happen: Quantified type variables should be instantiated before we get here.
    (TQuant {}, _) -> do
        lt <- showTypeVarIO av
        rt <- showTypeVarIO bv
        error $ printf "Internal error: QVar made it to unify %s and %s" lt rt
    (_, TQuant {}) -> do
        lt <- showTypeVarIO av
        rt <- showTypeVarIO bv
        error $ printf "Internal error: QVar made it to unify %s and %s" lt rt

    _ ->
        unificationError "" av bv

unifyRecord :: TypeVar -> TypeVar -> IO ()
unifyRecord av bv = do
    TRecord a <- readIORef av
    TRecord b <- readIORef bv
    let RecordType aOpen aRows = a
        RecordType bOpen bRows = b
    let aFields = sort $ map fst aRows
    let bFields = sort $ map fst bRows

    when (aOpen == RecordQuantified || bOpen == RecordQuantified) $
        error "Internal error: Encountered a quantified record.  This should have been instantiated away"

    let aRequired = RecordClose == aOpen
        bRequired = RecordClose == bOpen

    let allKeys = nub $ sort (aFields ++ bFields)
    newFields <- forM allKeys $ \key -> do
        case (aRequired, lookup key aRows, bRequired, lookup key bRows) of
            (_, Just t1, _, Just t2) -> do
                unify t1 t2
                return (key, t1)

            (_    , Just t1, False, Nothing) ->
                return (key, t1)
            (False, Nothing, _    , Just t2) ->
                return (key, t2)

            (True, Nothing, _, _) ->
                unificationError ("Field '" ++ Text.unpack key ++ "' not found in quantified record") av bv

            (_, _, True, Nothing) ->
                unificationError ("Field '" ++ Text.unpack key ++ "' not found in quantified record") av bv

            (False, Nothing, False, Nothing) -> do
                error "Internal error in unifyRecord: This should be very impossible"

    let open' = case (aOpen, bOpen) of
            (RecordClose, _)         -> RecordClose
            (_, RecordClose)         -> RecordClose
            (RecordQuantified, _)    -> RecordQuantified
            (_, RecordQuantified)    -> RecordQuantified
            (RecordFree, RecordFree) -> RecordFree

    writeIORef av $ TRecord $ RecordType open' newFields

    let i = 888 -- hack
    writeIORef bv (TVar i $ Link av)

occurs :: VarLink TypeVar -> TypeVar -> IO ()
occurs tvr ty = do
    tyy <- readIORef ty
    case tyy of
        TVar _ ty''
            | tvr == ty'' -> do
                error $ "Occurs check failed"
            | otherwise -> do
                case ty'' of
                    Link ty''' -> occurs tvr ty'''
                    _ -> return ()
        TFun arg ret -> do
            mapM_ (occurs tvr) arg
            occurs tvr ret
        TUserType _ tvars -> do
            mapM_ (occurs tvr) tvars
        TRecord (RecordType _ rows) -> do
            forM_ rows $ \(_, rowTy) ->
                occurs tvr rowTy
        TPrimitive {} ->
            return ()
        TQuant {} ->
            return ()

checkDecl :: Env -> Declaration Pos -> IO (Declaration TypeVar)
checkDecl env (Declaration export decl) = fmap (Declaration export) $ case decl of
    DData name typeVars variants ->
        -- TODO: Verify that all types referred to by variants exist, or are typeVars
        return $ DData name typeVars variants
    DJSData name variants ->
        return $ DJSData name variants
    DType (TypeAlias name typeVars ident) ->
        return $ DType $ TypeAlias name typeVars ident
    DFun (FunDef pos name args body) -> do
        ty <- freshType env
        HashTable.insert name ty (eBindings env)
        let expr = EFun pos args body
        expr'@(EFun _ _ body') <- check env expr
        unify (edata expr') ty
        quantify ty
        return $ DFun $ FunDef (edata expr') name args body'
    DLet _ mut name maybeAnnot expr -> do
        expr' <- check env expr
        let ty = edata expr'
        HashTable.insert name ty (eBindings env)
        forM_ maybeAnnot $ \annotation -> do
            annotTy <- resolveTypeIdent env [] annotation
            unify ty annotTy
        quantify ty
        return $ DLet (edata expr') mut name maybeAnnot expr'

buildTypeEnvironment :: Maybe (Module i ImmutableTypeVar) -> [Declaration a] -> IO Env
buildTypeEnvironment prelude decls = do
    numTy  <- newIORef $ TPrimitive Number
    unitTy <- newIORef $ TPrimitive Unit
    strTy  <- newIORef $ TPrimitive String

    e <- newEnv Nothing
    typeEnv <- newIORef $ HashMap.fromList
        [ ("Number", numTy)
        , ("Unit", unitTy)
        , ("String", strTy)
        ]

    -- inject stuff from the prelude into this global environment
    -- TODO: rather than injecting symbols, we may need a mechanism to refer
    -- to imported symbols
    case prelude of
      Just prelude' ->
        forM_ (mDecls prelude') $ \(Declaration _ decl) -> case decl of
            DJSData name variants -> do
                let encodeJSVariant (JSVariant n _) = TVariant n []
                tr <- newIORef $ TUserType (TUserTypeDef name [] $ map encodeJSVariant variants) []
                HashTable.insert name tr typeEnv

                forM_ variants $ \(JSVariant vname _) -> do
                    HashTable.insert vname tr (eBindings e)

            _ -> return ()
      _ -> return ()

    -- qvarsRef :: IORef HashMap (Name, [(TypeVariable, TypeVar)])
    qvarsRef <- HashTable.new

    typeAliasesRef <- HashTable.new

    -- First, populate the type environment.  Variant parameter types are all initially free.
    forM_ decls $ \(Declaration _ decl) -> case decl of
        DData name typeVarNames variants -> do
            typeVars <- forM typeVarNames $ const $ do
                ft <- freshType e
                quantify ft
                return ft
            HashTable.insert name (zip typeVarNames typeVars) qvarsRef

            variants' <- forM variants $ \Variant{..} -> do
                tvParameters <- forM vparameters $ const $ freshType e
                let tvName = vname
                return TVariant{..}

            let typeDef = TUserTypeDef
                    { tuName = name
                    , tuParameters = typeVars
                    , tuVariants = variants'
                    }
            userType <- newIORef $ TUserType typeDef typeVars
            modifyIORef' typeEnv (HashMap.insert name userType)
        DType ty@(TypeAlias name _ _) -> do
            HashTable.insert name ty typeAliasesRef
        _ -> return ()

    qvars <- readIORef qvarsRef
    te <- readIORef typeEnv
    ta <- readIORef typeAliasesRef
    let env = e{eTypeBindings=te, eTypeAliases=ta}

    -- Second, unify parameter types
    forM_ decls $ \(Declaration _ decl) -> case decl of
        DData name _typeVarNames variants -> do
            Just ty <- HashTable.lookup name typeEnv
            TUserType typeDef _ <- readIORef ty

            let TUserTypeDef { tuVariants = tvariants } = typeDef
            forM_ (zip variants tvariants) $ \(v, tv) -> do
                forM_ (zip (vparameters v) (tvParameters tv)) $ \(typeIdent, typeVar) -> do
                    let Just qv = HashMap.lookup name qvars
                    t <- resolveTypeIdent env qv typeIdent
                    unify typeVar t
        _ -> return ()

    let computeVarianTPrimitive ty qvarNames _name argTypeIdents = case argTypeIdents of
            [] ->
                return ty
            _ -> do
                resolvedArgTypes <- mapM (resolveTypeIdent env qvarNames) argTypeIdents
                newIORef $ TFun resolvedArgTypes ty

    intrinsics <- Intrinsic.intrinsics

    forM_ (HashMap.toList intrinsics) $ \(name, intrin) -> do
        let Intrinsic{..} = intrin
        HashTable.insert name iType (eBindings env)

    -- Note to self: Here we need to match the names of the types of each variant up with concrete types, but also
    -- with the TypeVars created in the type environment.
    forM_ decls $ \(Declaration _ decl) -> case decl of
        DData name _ variants -> do
            let Just userType = HashMap.lookup name te
            let Just qvarTable = HashMap.lookup name qvars
            forM_ variants $ \(Variant vname vdata) -> do
                ctorType <- computeVarianTPrimitive userType qvarTable vname vdata
                HashTable.insert vname ctorType (eBindings env)
        _ -> return ()

    return env{eTypeBindings=te} -- just env?

resolveTypeIdent :: Env -> [(TypeName, TypeVar)] -> TypeIdent -> IO TypeVar
resolveTypeIdent env qvarTable typeIdent =
    go typeIdent
  where
    Env{..} = env
    go (TypeIdent typeName typeParameters) =
        if isCapitalized typeName
            then case HashMap.lookup typeName eTypeBindings of
                Just ty -> do
                    ty' <- readIORef ty
                    case ty' of
                        TPrimitive {} ->
                            if [] /= typeParameters
                                then error "Primitive types don't take type parameters"
                                else return ty
                        TUserType def _ ->
                            if length qvarTable /= length typeParameters
                                then
                                    error $ printf "Type %s takes %i type parameters.  %i given" (show $ tuName def) (length qvarTable) (length typeParameters)
                                else do
                                    params <- mapM go typeParameters
                                    newIORef $ TUserType def params
                        _ ->
                            return ty
                Nothing -> case HashMap.lookup typeName eTypeAliases of
                    Just (TypeAlias aliasName aliasParams aliasedIdent) -> do
                        when (length aliasParams /= length typeParameters) $
                            error $ printf "Type alias %s takes %i parameters.  %i given" (Text.unpack aliasName) (length aliasParams) (length typeParameters)

                        argTypes <- mapM (resolveTypeIdent env qvarTable) typeParameters
                        let qtab = zip aliasParams argTypes

                        resolveTypeIdent env qtab aliasedIdent
                    Nothing ->
                        error $ printf "Constructor uses nonexistent type %s" (show typeName)
            else case lookup typeName qvarTable of
                Nothing ->
                    error $ printf "Constructor uses nonexistent type variable %s" (show typeName)
                Just t ->
                    return t

    go (RecordIdent rows) = do
        rows' <- forM rows $ \(rowName, rowTy) ->
            fmap (rowName,) (go rowTy)
        newIORef $ TRecord $ RecordType RecordClose rows'

    go (FunctionIdent argTypes reTPrimitive) = do
        argTypes' <- mapM go argTypes
        reTPrimitive' <- go reTPrimitive
        newIORef $ TFun argTypes' reTPrimitive'

run :: Maybe (Module i ImmutableTypeVar) -> Module i Pos -> IO (Module i TypeVar)
run prelude Module{..} = do
    env <- buildTypeEnvironment prelude mDecls
    decls <- forM mDecls (checkDecl env)
    return Module
        { mImports=mImports
        , mDecls=decls
        }
