{-# OPTIONS_GHC -F -pgmF htfpp #-}
{-# LANGUAGE OverloadedStrings #-}

module JSBackendTest (htf_thisModulesTests) where

import Data.Text (Text)
import Test.Framework
import qualified Crux.Module
import qualified Crux.Gen as Gen
import qualified Crux.Backend.JS as JS
import qualified Crux.JSTree as JSTree

genDoc' :: Text -> IO (Either String Text)
genDoc' src = do
    mod' <- Crux.Module.loadModuleFromSource "<string>" src
    case mod' of
        Left err ->
            return $ Left err
        Right m -> do
            modul <- Gen.generateModule m
            return $ Right $ JSTree.renderDocument $ JS.generateModule modul

genDoc :: Text -> IO Text
genDoc src = do
    rv <- genDoc' src
    case rv of
        Left err -> error err
        Right stmts -> return stmts

test_direct_prints = do
    doc <- genDoc "let _ = print(10);"
    assertEqual
        "var _ = (function (){\nvar $0 = Prelude.print(10);\nreturn $0;\n}\n)();\n"
        doc

test_return_from_function = do
    doc <- genDoc "fun f() { return 1; }"
    assertEqual
        "function f(){\nreturn 1;\n}\n"
        doc

test_export_function = do
    doc <- genDoc "export fun f() { 1; }"
    assertEqual
        "function f(){\nreturn 1;\n}\n(exports).f = f;\n"
        doc

test_return_from_branch = do
    result <- genDoc "fun f() { if True then return 1 else return 2; }"
    assertEqual
        "function f(){\nvar $0;\nif(Prelude.True){\nreturn 1;\n}\nelse {\nreturn 2;\n}\nreturn $0;\n}\n"
        result

test_branch_with_value = do
    result <- genDoc "let x = if True then 1 else 2;"
    assertEqual
        "var x = (function (){\nvar $0;\nif(Prelude.True){\n$0 = 1;\n}\nelse {\n$0 = 2;\n}\nreturn $0;\n}\n)();\n"
        result

test_jsffi_data = do
    result <- genDoc "data jsffi JST { A = undefined, B = null, C = true, D = false, E = 10, F = \"hi\", }"
    assertEqual
        "var A = (void 0);\nvar B = null;\nvar C = true;\nvar D = false;\nvar E = 10;\nvar F = \"hi\";\n"
        result