{-# LANGUAGE NamedFieldPuns, RecordWildCards #-}

module Crux.Typecheck.Unify where

import           Crux.AST
import qualified Crux.MutableHashTable as HashTable
import           Crux.Prelude
import           Crux.Typecheck.Types
import           Data.List             (sort)
import           Text.Printf           (printf)
import Crux.TypeVar
import Crux.Error

freshTypeIndex :: MonadIO m => Env -> m Int
freshTypeIndex Env{eNextTypeIndex} = do
    modifyIORef' eNextTypeIndex (+1)
    readIORef eNextTypeIndex

freshType :: MonadIO m => Env -> m TypeVar
freshType env = do
    index <- freshTypeIndex env
    newTypeVar $ TUnbound index

freshRowVariable :: Env -> IO RowVariable
freshRowVariable env =
    RowVariable <$> freshTypeIndex env

data RecordSubst
    = SFree RowVariable
    | SQuant RowVariable
    | SRows [TypeRow TypeVar]

instantiateUserType :: IORef (HashMap Int TypeVar) -> Env -> TUserTypeDef TypeVar -> [TypeVar] -> IO (TypeVar, [TVariant TypeVar])
instantiateUserType subst env def tyVars = do
    recordSubst <- HashTable.new
    typeVars' <- for tyVars $ instantiate' subst recordSubst env
    let userType = TUserType def typeVars'
    variants <- for (tuVariants def) $ \variant -> do
        paramTypes <- for (tvParameters variant) $ \param -> do
            instantiate' subst recordSubst env param
        return variant{tvParameters=paramTypes}
    return (userType, variants)

instantiateRecord
    :: IORef (HashMap Int TypeVar)
    -> IORef (HashMap RowVariable TypeVar)
    -> Env
    -> [TypeRow TypeVar]
    -> RecordOpen
    -> IO TypeVar
instantiateRecord subst recordSubst env rows open = do
    rows' <- for rows $ \TypeRow{..} -> do
        rowTy' <- instantiate' subst recordSubst env trTyVar
        let mut' = case trMut of
                RQuantified -> RFree
                _ -> trMut
        return TypeRow{trName, trMut=mut', trTyVar=rowTy'}

    open' <- case open of
        RecordQuantified i -> do
            return $ RecordFree i
        RecordFree _ -> do
            fail $ "Instantiation of a free row variable -- this should never happen"
        RecordClose -> do
            return $ RecordClose

    recordType <- newIORef $ RRecord $ RecordType open' rows'
    return $ TRecord recordType

instantiate' :: IORef (HashMap Int TypeVar) -> IORef (HashMap RowVariable TypeVar) -> Env -> TypeVar -> IO TypeVar
instantiate' subst recordSubst env ty = case ty of
    TypeVar ref -> do
        readIORef ref >>= \case
            TUnbound _ -> do
                -- We instantiate unbound type variables when recursively
                -- referencing a function whose parameter and return types are
                -- not yet quantified.
                return ty
            TBound tv' -> do
                instantiate' subst recordSubst env tv'
    TQuant name -> do
        HashTable.lookup name subst >>= \case
            Just v ->
                return v
            Nothing -> do
                tv <- freshType env
                HashTable.insert name tv subst
                return tv
    TFun param ret -> do
        ty1 <- for param $ instantiate' subst recordSubst env
        ty2 <- instantiate' subst recordSubst env ret
        return $ TFun ty1 ty2
    TUserType def tyVars -> do
        typeVars' <- for tyVars $ instantiate' subst recordSubst env
        return $ TUserType def typeVars'
    TRecord ref' -> followRecordTypeVar ref' >>= \(RecordType open rows) -> do
        let rv = case open of
                RecordFree r -> Just r
                RecordQuantified r -> Just r
                _ -> Nothing
        case rv of
            Just rv' -> do
                HashTable.lookup rv' recordSubst >>= \case
                    Just rec -> return rec
                    Nothing -> do
                        tr <- instantiateRecord subst recordSubst env rows open
                        HashTable.insert rv' tr recordSubst
                        return tr
            Nothing ->
                instantiateRecord subst recordSubst env rows open

    TPrimitive {} -> return ty

quantify :: MonadIO m => TypeVar -> m ()
quantify ty = case ty of
    TypeVar ref -> do
        readIORef ref >>= \case
            TUnbound i -> do
                writeIORef ref $ TBound $ TQuant i
            TBound t -> do
                quantify t
    TQuant _ -> do
        return ()
    TFun param ret -> do
        for_ param quantify
        quantify ret
    TUserType _ tyParams ->
        for_ tyParams quantify
    TRecord ref -> followRecordTypeVar ref >>= \(RecordType open rows) -> do
        for_ rows $ \TypeRow{..} -> do
            quantify trTyVar
        case open of
            RecordFree ti -> do
                writeIORef ref $ RRecord $ RecordType (RecordQuantified ti) rows
            _ -> return ()
    TPrimitive {} ->
        return ()

instantiate :: Env -> TypeVar -> IO TypeVar
instantiate env t = do
    subst <- HashTable.new
    recordSubst <- HashTable.new
    instantiate' subst recordSubst env t

occurs :: Int -> TypeVar -> IO ()
occurs tvn = \case
    TypeVar ref -> readIORef ref >>= \case
        TUnbound q | tvn == q -> do
            throwIO $ OccursCheckFailed ()
        TUnbound _ -> do
            return ()
        TBound next -> do
            occurs tvn next
    TFun arg ret -> do
        for_ arg $ occurs tvn
        occurs tvn ret
    TUserType _ tvars -> do
        for_ tvars $ occurs tvn
    TRecord ref -> followRecordTypeVar ref >>= \(RecordType _open rows) -> do
        for_ rows $ \TypeRow{..} ->
            occurs tvn trTyVar
    TPrimitive {} ->
        return ()
    TQuant {} ->
        return ()

unificationError :: [Char] -> TypeVar -> TypeVar -> IO a
unificationError message a b = do
    throwIO $ UnificationError () message a b

lookupTypeRow :: Name -> [TypeRow t] -> Maybe (RowMutability, t)
lookupTypeRow name = \case
    [] -> Nothing
    (TypeRow{..}:rest)
        | trName == name -> Just (trMut, trTyVar)
        | otherwise -> lookupTypeRow name rest

unifyRecord :: TypeVar -> TypeVar -> IO ()
unifyRecord av bv = do
    -- do
    --     putStrLn " -- unifyRecord --"
    --     putStr "\t" >> showTypeVarIO av >>= putStrLn
    --     putStr "\t" >> showTypeVarIO bv >>= putStrLn

    let TRecord aRef = av
    let TRecord bRef = bv
    RecordType aOpen aRows <- followRecordTypeVar aRef
    RecordType bOpen bRows <- followRecordTypeVar bRef
    let aFields = sort $ map trName aRows
    let bFields = sort $ map trName bRows

    let coincidentRows = [(a, b) | a <- aRows, b <- bRows, trName a == trName b]
    let aOnlyRows = filter (\row -> trName row `notElem` bFields) aRows
    let bOnlyRows = filter (\row -> trName row `notElem` aFields) bRows
    let names trs = map trName trs

    coincidentRows' <- for coincidentRows $ \(lhs, rhs) -> do
        case unifyRecordMutability (trMut lhs) (trMut rhs) of
            Left err -> throwIO $ RecordMutabilityUnificationError () (trName lhs) err
            Right mut -> do
                unify (trTyVar lhs) (trTyVar rhs)
                return TypeRow
                    { trName = trName lhs
                    , trMut = mut
                    , trTyVar = trTyVar lhs
                    }

    case (aOpen, bOpen) of
        (RecordClose, RecordClose)
            | null aOnlyRows && null bOnlyRows -> do
                writeIORef bRef $ RRecord $ RecordType RecordClose coincidentRows'
                writeIORef aRef $ RBound $ bRef
            | otherwise ->
                unificationError "Closed row types must match exactly" av bv
        (RecordClose, RecordFree {})
            | null bOnlyRows -> do
                writeIORef aRef $ RRecord $ RecordType RecordClose (coincidentRows' ++ aOnlyRows)
                writeIORef bRef $ RBound $ aRef
            | otherwise ->
                unificationError (printf "Record has fields %s not in closed record" (show $ names bOnlyRows)) av bv
        (RecordFree {}, RecordClose)
            | null aOnlyRows -> do
                writeIORef bRef $ RRecord $ RecordType RecordClose (coincidentRows' ++ bOnlyRows)
                writeIORef aRef $ RBound bRef
            | otherwise ->
                unificationError (printf "Record has fields %s not in closed record" (show $ names aOnlyRows)) av bv
        (RecordClose, RecordQuantified {}) ->
            error "Cannot unify closed record with quantified record"
        (RecordQuantified {}, RecordClose) ->
            error "Cannot unify closed record with quantified record"
        (RecordFree {}, RecordFree {}) -> do
            writeIORef bRef $ RRecord $ RecordType aOpen (coincidentRows' ++ aOnlyRows ++ bOnlyRows)
            writeIORef aRef $ RBound bRef
        (RecordFree {}, RecordQuantified {})
            | null aOnlyRows -> do
                writeIORef bRef $ RRecord $ RecordType bOpen (coincidentRows' ++ bOnlyRows)
                writeIORef aRef $ RBound bRef
            | otherwise ->
                error "lhs record has rows not in quantified record"
        (RecordQuantified {}, RecordFree {})
            | null bOnlyRows -> do
                writeIORef aRef $ RRecord $ RecordType aOpen (coincidentRows' ++ aOnlyRows)
                writeIORef bRef $ RBound aRef
            | otherwise ->
                error "rhs record has rows not in quantified record"
        (RecordQuantified a, RecordQuantified b)
            | not (null aOnlyRows) ->
                error "lhs quantified record has rows not in rhs quantified record"
            | not (null bOnlyRows) ->
                error "rhs quantified record has rows not in lhs quantified record"
            | a /= b ->
                error "Quantified records do not have the same qvar!"
            | otherwise -> do
                writeIORef aRef $ RRecord $ RecordType aOpen coincidentRows'
                -- Is this a bug? I copied it verbatim from what was here. -- chad
                writeIORef aRef $ RBound bRef
                {-
                writeTypeVar av (TRecord $ RecordType aOpen coincidentRows')
                writeTypeVar av (TBound bv)
                -}

    -- do
    --     putStrLn "\t -- after --"
    --     putStr "\t" >> showTypeVarIO av >>= putStrLn
    --     putStr "\t" >> showTypeVarIO bv >>= putStrLn
    --     putStrLn ""

unifyRecordMutability :: RowMutability -> RowMutability -> Either Prelude.String RowMutability
unifyRecordMutability m1 m2 = case (m1, m2) of
    (RImmutable, RImmutable) -> Right RImmutable
    (RImmutable, RMutable) -> Left "Record field mutability does not match"
    (RImmutable, RFree) -> Right RImmutable
    (RMutable, RMutable) -> Right RMutable
    (RMutable, RImmutable) -> Left "Record field mutability does not match"
    (RMutable, RFree) -> Right RMutable
    (RFree, RFree) -> Right RFree
    (RFree, RImmutable) -> Right RImmutable
    (RFree, RMutable) -> Right RMutable
    (RQuantified, _) -> Left "Quant!! D:"
    (_, RQuantified) -> Left "Quant2!! D:"

unify :: TypeVar -> TypeVar -> IO ()
unify av' bv' = do
    av <- followTypeVar av'
    bv <- followTypeVar bv'
    if av == bv then
        return ()
    else case (av, bv) of
        -- thanks to followTypeVar, the only TypeVar case here is TUnbound
        (TypeVar aref, TypeVar bref) -> do
            (TUnbound a') <- readIORef aref
            (TUnbound b') <- readIORef bref
            if a' == b' then
                return ()
            else do
                occurs a' bv
                writeIORef aref $ TBound bv
        (TypeVar aref, _) -> do
            (TUnbound a') <- readIORef aref
            occurs a' bv
            writeIORef aref $ TBound bv
        (_, TypeVar bref) -> do
            (TUnbound b') <- readIORef bref
            occurs b' av
            writeIORef bref $ TBound av

        (TPrimitive aType, TPrimitive bType)
            | aType == bType ->
                return ()
            | otherwise -> do
                unificationError "" av bv

        (TUserType ad atv, TUserType bd btv)
            | userTypeIdentity ad == userTypeIdentity bd -> do
                -- TODO: assert the two lists have the same length
                for_ (zip atv btv) $ uncurry unify
            | otherwise -> do
                unificationError "" av bv

        (TRecord {}, TRecord {}) ->
            unifyRecord av bv

        (TFun aa ar, TFun ba br) -> do
            when (length aa /= length ba) $
                unificationError "" av bv

            for_ (zip aa ba) $ uncurry unify
            unify ar br

        (TQuant i, TQuant j) | i == j ->
            return ()

        _ ->
            unificationError "" av bv
