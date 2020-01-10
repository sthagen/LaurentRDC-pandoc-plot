{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}
{-# LANGUAGE TemplateHaskell   #-}

{-|
Module      : $header$
Copyright   : (c) Laurent P René de Cotret, 2020
License     : GNU GPL, version 2 or above
Maintainer  : laurent.decotret@outlook.com
Stability   : internal
Portability : portable

This module defines types and functions that help
with keeping track of figure specifications
-}
module Text.Pandoc.Filter.Plot.Parse ( 
      parseFigureSpec 
    , captionReader
) where

import           Control.Monad                   (join)
import           Control.Monad.Reader            (ask)

import           Data.Default.Class              (def)
import           Data.List                       (intersperse)
import qualified Data.Map.Strict                 as Map
import           Data.Maybe                      (fromMaybe)
import           Data.Monoid                     ((<>))
import           Data.String                     (fromString)
import           Data.Text                       (Text, pack, unpack)
import           Data.Version                    (showVersion)

import           Paths_pandoc_plot               (version)

import           System.FilePath                 (makeValid)

import           Text.Pandoc.Definition          (Block (..), Inline,
                                                    Pandoc (..))

import           Text.Pandoc.Class               (runPure)
import           Text.Pandoc.Extensions          (Extension (..),
                                                    extensionsFromList)
import           Text.Pandoc.Options             (ReaderOptions (..))
import           Text.Pandoc.Readers             (readMarkdown)

import           Text.Pandoc.Filter.Plot.Types
import           Text.Pandoc.Filter.Plot.Configuration

-- | Determine inclusion specifications from @Block@ attributes.
parseFigureSpec :: RendererM m => Block -> m (Maybe FigureSpec)
parseFigureSpec (CodeBlock (id', cls, attrs) content) = do
    rendererName <- name
    if not (rendererName `elem` cls)
        then return Nothing 
        else Just <$> figureSpec

    where
        attrs'        = Map.fromList attrs
        includePath   = unpack <$> Map.lookup includePathKey attrs' -- TODO: this
        header        = "# Generated by pandoc-plot " <> ((pack . showVersion) version)

        figureSpec :: RendererM m => m FigureSpec
        figureSpec = do
            config <- ask
            extraAttrs' <- parseExtraAttrs attrs'
            let includeScript = mempty -- TODO: this
                -- Filtered attributes that are not relevant to pandoc-plot
                -- Note that certain Renderers have extra attrs,
                filteredAttrs = filter (\(k, _) -> k `notElem` inclusionKeys && (Map.notMember k extraAttrs')) attrs
            
            return $
                FigureSpec
                    { caption        = Map.findWithDefault mempty captionKey attrs'
                    , withLinks      = fromMaybe (defaultWithLinks config) $ readBool <$> Map.lookup withLinksKey attrs'
                    , script         = mconcat $ intersperse "\n" [header, includeScript, content]
                    , saveFormat     = fromMaybe (defaultSaveFormat config) $ (fromString . unpack) <$> Map.lookup saveFormatKey attrs'
                    , directory      = makeValid $ unpack $ Map.findWithDefault (pack $ defaultDirectory config) directoryKey attrs'
                    , dpi            = fromMaybe (defaultDPI config) $ (read . unpack) <$> Map.lookup dpiKey attrs'
                    , extraAttrs     = Map.toList extraAttrs'
                    , blockAttrs     = (id', cls, filteredAttrs)
                    }

parseFigureSpec _ = return Nothing

-- | Reader options for captions.
readerOptions :: ReaderOptions
readerOptions = def
    {readerExtensions =
        extensionsFromList
            [ Ext_tex_math_dollars
            , Ext_superscript
            , Ext_subscript
            , Ext_raw_tex
            ]
    }


-- | Read a figure caption in Markdown format. LaTeX math @$...$@ is supported,
-- as are Markdown subscripts and superscripts.
captionReader :: Text -> Maybe [Inline]
captionReader t = either (const Nothing) (Just . extractFromBlocks) $ runPure $ readMarkdown' t
    where
        readMarkdown' = readMarkdown readerOptions

        extractFromBlocks (Pandoc _ blocks) = mconcat $ extractInlines <$> blocks

        extractInlines (Plain inlines)          = inlines
        extractInlines (Para inlines)           = inlines
        extractInlines (LineBlock multiinlines) = join multiinlines
        extractInlines _                        = []


-- | Flexible boolean parsing
readBool :: Text -> Bool
readBool s | s `elem` ["True",  "true",  "'True'",  "'true'",  "1"] = True
           | s `elem` ["False", "false", "'False'", "'false'", "0"] = False
           | otherwise = error $ unpack $ mconcat ["Could not parse '", s, "' into a boolean. Please use 'True' or 'False'"]
