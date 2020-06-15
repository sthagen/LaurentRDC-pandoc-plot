{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE QuasiQuotes           #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TemplateHaskell       #-}

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
      plotToolkit
    , parseFigureSpec
    , captionReader
    , defaultReaderOptions
) where

import           Control.Monad                     (join, when)

import           Data.List                         (intersperse)
import qualified Data.Map.Strict                   as Map
import           Data.Maybe                        (fromMaybe, listToMaybe)
import           Data.String                       (fromString)
import           Data.Text                         (Text, pack, unpack)
import qualified Data.Text.IO                      as TIO
import           Data.Version                      (showVersion)

import           Paths_pandoc_plot                 (version)

import           System.FilePath                   (makeValid)

import           Text.Pandoc.Definition            (Block (..), Inline,
                                                    Pandoc (..), Format(..))

import           Text.Pandoc.Class                 (runPure)
import           Text.Pandoc.Extensions            (emptyExtensions)
import           Text.Pandoc.Options               (ReaderOptions (..), TrackChanges(..))
import           Text.Pandoc.Readers               (getReader, Reader(..))

import           Text.Pandoc.Filter.Plot.Renderers
import           Text.Pandoc.Filter.Plot.Monad

tshow :: Show a => a -> Text
tshow = pack . show

-- | Determine inclusion specifications from @Block@ attributes.
-- If an environment is detected, but the save format is incompatible,
-- an error will be thrown.
parseFigureSpec :: Block -> PlotM (Maybe FigureSpec)
parseFigureSpec block@(CodeBlock (id', classes, attrs) content) = do
    let toolkit = plotToolkit block
    case toolkit of
        Nothing -> return Nothing
        Just tk -> do
            if not (cls tk `elem` classes)
                then return Nothing
                else Just <$> figureSpec tk

    where
        attrs'        = Map.fromList attrs
        preamblePath  = unpack <$> Map.lookup (tshow PreambleK) attrs'

        figureSpec :: Toolkit -> PlotM FigureSpec
        figureSpec toolkit = do
            conf <- asks envConfig
            let extraAttrs' = parseExtraAttrs toolkit attrs'
                header = comment toolkit $ "Generated by pandoc-plot " <> ((pack . showVersion) version)
                defaultPreamble = preambleSelector toolkit conf

            includeScript <- fromMaybe
                                (return defaultPreamble)
                                ((liftIO . TIO.readFile) <$> preamblePath)
            let -- Filtered attributes that are not relevant to pandoc-plot
                -- This presumes that inclusionKeys includes ALL possible keys, for all toolkits
                filteredAttrs = filter (\(k, _) -> k `notElem` (tshow <$> inclusionKeys)) attrs
                defWithSource = defaultWithSource conf
                defSaveFmt = defaultSaveFormat conf
                defDPI = defaultDPI conf

            let caption        = Map.findWithDefault mempty (tshow CaptionK) attrs'
                withSource     = fromMaybe defWithSource $ readBool <$> Map.lookup (tshow WithSourceK) attrs'
                script         = mconcat $ intersperse "\n" [header, includeScript, content]
                saveFormat     = fromMaybe defSaveFmt $ (fromString . unpack) <$> Map.lookup (tshow SaveFormatK) attrs'
                directory      = makeValid $ unpack $ Map.findWithDefault (pack $ defaultDirectory conf) (tshow DirectoryK) attrs'
                dpi            = fromMaybe defDPI $ (read . unpack) <$> Map.lookup (tshow DpiK) attrs'
                extraAttrs     = Map.toList extraAttrs'
                blockAttrs     = (id', classes, filteredAttrs)

            -- This is the first opportunity to check save format compatibility
            let saveFormatSupported = saveFormat `elem` (supportedSaveFormats toolkit)
            when (not saveFormatSupported) $ do
                let msg = pack $ mconcat ["Save format ", show saveFormat, " not supported by ", show toolkit ]
                err msg
            return FigureSpec{..}

parseFigureSpec _ = return Nothing


-- | Determine which toolkit should be used to render the plot
-- from a code block, if any.
plotToolkit :: Block -> Maybe Toolkit
plotToolkit (CodeBlock (_, classes, _) _) =
    listToMaybe $ filter (\tk->cls tk `elem` classes) toolkits
plotToolkit _ = Nothing


-- | Reader a caption, based on input document format
captionReader :: Format -> Text -> Maybe [Inline]
captionReader (Format f) t = either (const Nothing) (Just . extractFromBlocks) $ runPure $ do
    (reader, exts) <- getReader f
    let readerOpts = defaultReaderOptions {readerExtensions = exts}
    -- Assuming no ByteString readers...
    case reader of
        TextReader fct -> fct readerOpts t
        _              -> return mempty
    where
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


-- | Default reader options, straight out of Text.Pandoc.Options
defaultReaderOptions :: ReaderOptions
defaultReaderOptions = 
    ReaderOptions
        { readerExtensions            = emptyExtensions
        , readerStandalone            = False
        , readerColumns               = 80
        , readerTabStop               = 4
        , readerIndentedCodeClasses   = []
        , readerAbbreviations         = mempty
        , readerDefaultImageExtension = ""
        , readerTrackChanges          = AcceptChanges
        , readerStripComments         = False
        }