{-# LANGUAGE CPP, DeriveDataTypeable, ForeignFunctionInterface,
    GeneralizedNewtypeDeriving #-}
-- |
-- Module      : Data.Text.ICU.Normalizer
-- Copyright   : (c) Bryan O'Sullivan 2009
--
-- License     : BSD-style
-- Maintainer  : bos@serpentine.com
-- Stability   : experimental
-- Portability : GHC
--
-- Character set normalization functions for Unicode, implemented as
-- bindings to the International Components for Unicode (ICU)
-- libraries.

module Data.Text.ICU.Normalizer
    (
    -- * Unicode normalization API
    -- $api
      NormalizationMode(..)
    -- * Normalization functions
    , normalize
    -- * Normalization checks
    , NormalizationCheckResult(..)
    , quickCheck
    , isNormalized
    -- * Normalization-sensitive comparison
    , CompareOption
    , u_INPUT_IS_FCD
    , u_COMPARE_CODE_POINT_ORDER
    , u_COMPARE_IGNORE_CASE
    , compare
    ) where

#ifdef mingw32_HOST_OS
#define U_HAVE_INTTYPES_H 1
#endif

#include <unicode/unorm.h>

import Control.Exception (throw)
import Control.Monad (when)
import Data.Text (Text)
import Data.Text.Foreign (fromPtr, useAsPtr)
import Data.Text.ICU.Error (u_BUFFER_OVERFLOW_ERROR)
import Data.Text.ICU.Error.Internal (UErrorCode, isFailure, handleError, withError)
import Data.Text.ICU.Internal (UBool, UChar, asBool, asOrdering)
import Data.Typeable (Typeable)
import Data.Int (Int32)
import Data.Word (Word32)
import Foreign.C.Types (CInt)
import Foreign.Marshal.Array (allocaArray)
import Foreign.Ptr (Ptr)
import System.IO.Unsafe (unsafePerformIO)
import Prelude hiding (compare)
import Data.List (foldl')
import Data.Bits ((.|.))

-- $api
--
-- 'normalize' transforms Unicode text into an equivalent composed or
-- decomposed form, allowing for easier sorting and searching of text.
-- 'normalize' supports the standard normalization forms described in
-- <http://www.unicode.org/unicode/reports/tr15/>,
-- Unicode Standard Annex #15: Unicode Normalization Forms.
--
-- Characters with accents or other adornments can be encoded in
-- several different ways in Unicode.  For example, take the character A-acute.
-- In Unicode, this can be encoded as a single character (the
-- \"composed\" form):
--
-- @
--      &#x00C1;   00C1    LATIN CAPITAL LETTER A WITH ACUTE
-- @
--
-- or as two separate characters (the \"decomposed\" form):
--
-- @
--      &#x0041;   0041    LATIN CAPITAL LETTER A
--      &#x0301;    0301    COMBINING ACUTE ACCENT
-- @
--
-- To a user of your program, however, both of these sequences should
-- be treated as the same \"user-level\" character \"A with acute
-- accent\".  When you are searching or comparing text, you must
-- ensure that these two sequences are treated equivalently.  In
-- addition, you must handle characters with more than one accent.
-- Sometimes the order of a character's combining accents is
-- significant, while in other cases accent sequences in different
-- orders are really equivalent.
--
-- Similarly, the string \"ffi\" can be encoded as three separate letters:
--
-- @
--      f   0066    LATIN SMALL LETTER F
--      f   0066    LATIN SMALL LETTER F
--      i   0069    LATIN SMALL LETTER I
-- @
--
-- or as the single character
--
-- @
--      &#xFB03;   FB03    LATIN SMALL LIGATURE FFI
-- @
--
-- The \"ffi\" ligature is not a distinct semantic character, and
-- strictly speaking it shouldn't be in Unicode at all, but it was
-- included for compatibility with existing character sets that
-- already provided it.  The Unicode standard identifies such
-- characters by giving them \"compatibility\" decompositions into the
-- corresponding semantic characters.  When sorting and searching, you
-- will often want to use these mappings.
--
-- 'normalize' helps solve these problems by transforming text into
-- the canonical composed and decomposed forms as shown in the first
-- example above.  In addition, you can have it perform compatibility
-- decompositions so that you can treat compatibility characters the
-- same as their equivalents.  Finally, 'normalize' rearranges accents
-- into the proper canonical order, so that you do not have to worry
-- about accent rearrangement on your own.
--
-- Form 'FCD', \"Fast C or D\", is also designed for collation.  It
-- allows to work on strings that are not necessarily normalized with
-- an algorithm (like in collation) that works under \"canonical
-- closure\", i.e., it treats precomposed characters and their
-- decomposed equivalents the same.
--
-- It is not a normalization form because it does not provide for
-- uniqueness of representation. Multiple strings may be canonically
-- equivalent (their NFDs are identical) and may all conform to 'FCD'
-- without being identical themselves.
--
-- The form is defined such that the \"raw decomposition\", the
-- recursive canonical decomposition of each character, results in a
-- string that is canonically ordered. This means that precomposed
-- characters are allowed for as long as their decompositions do not
-- need canonical reordering.
--
-- Its advantage for a process like collation is that all 'NFD' and
-- most 'NFC' texts - and many unnormalized texts - already conform to
-- 'FCD' and do not need to be normalized ('NFD') for such a
-- process. The 'FCD' 'quickCheck' will return 'Yes' for most strings
-- in practice.
--
-- @'normalize' 'FCD'@ may be implemented with 'NFD'.
--
-- For more details on 'FCD' see the collation design document:
-- <http://source.icu-project.org/repos/icu/icuhtml/trunk/design/collation/ICU_collation_design.htm>
--
-- ICU collation performs either 'NFD' or 'FCD' normalization
-- automatically if normalization is turned on for the collator
-- object.  Beyond collation and string search, normalized strings may
-- be useful for string equivalence comparisons,
-- transliteration/transcription, unique representations, etc.
--
-- The W3C generally recommends to exchange texts in 'NFC'.  Note also
-- that most legacy character encodings use only precomposed forms and
-- often do not encode any combining marks by themselves. For
-- conversion to such character encodings the Unicode text needs to be
-- normalized to 'NFC'.  For more usage examples, see the Unicode
-- Standard Annex.

newtype CompareOption = CompareOption {
      fromCompareOption :: Word32
    } deriving (Eq, Typeable)

foldCompareOptions :: [CompareOption] -> Word32
foldCompareOptions = foldl' orO 0
    where a `orO` b = a .|. fromCompareOption b

#{enum CompareOption, CompareOption,
  u_INPUT_IS_FCD = UNORM_INPUT_IS_FCD,
  u_COMPARE_CODE_POINT_ORDER = U_COMPARE_CODE_POINT_ORDER,
  u_COMPARE_IGNORE_CASE = U_COMPARE_IGNORE_CASE
  }

type UNormalizationMode = CInt

data NormalizationMode
    = None   -- ^ No decomposition/composition.
    | NFD    -- ^ Canonical decomposition.
    | NFKD   -- ^ Compatibility decomposition.
    | NFC    -- ^ Canonical decomposition followed by canonical composition.
    | NFKC   -- ^ Compatibility decomposition followed by canonical composition.
    | FCD    -- ^ \"Fast C or D\" form.
      deriving (Eq, Show, Enum, Typeable)
                       
toNM :: NormalizationMode -> UNormalizationMode
toNM None = #const UNORM_NONE
toNM NFD  = #const UNORM_NFD
toNM NFKD = #const UNORM_NFKD
toNM NFC  = #const UNORM_NFC
toNM NFKC = #const UNORM_NFKC
toNM FCD  = #const UNORM_FCD

type UNormalizationCheckResult = CInt

data NormalizationCheckResult
    = No      -- ^ Text is not normalized.
    | Perhaps -- ^ It cannot be determined whether text is in normalized 
              -- form without further thorough checks.
    | Yes     -- ^ Text is in normalized form.
      deriving (Eq, Show, Enum, Typeable)
                              
toNCR :: UNormalizationCheckResult -> NormalizationCheckResult
toNCR (#const UNORM_NO)    = No
toNCR (#const UNORM_MAYBE) = Perhaps
toNCR (#const UNORM_YES)   = Yes
toNCR _                    = error "toNormalizationCheckResult"

-- | Normalize a string according the specified normalization mode.
normalize :: NormalizationMode -> Text -> Text
normalize mode t = unsafePerformIO . useAsPtr t $ \sptr slen ->
  let slen' = fromIntegral slen
      mode' = toNM mode
      loop dlen =
        (either loop return =<<) .
        allocaArray dlen $ \dptr -> do
          (err, newLen) <- withError $
              unorm_normalize sptr slen' mode' 0 dptr (fromIntegral dlen)
          when (isFailure err && err /= u_BUFFER_OVERFLOW_ERROR) $
            throw err
          let newLen' = fromIntegral newLen
          if newLen' > dlen
            then return (Left newLen')
            else Right `fmap` fromPtr dptr newLen'
  in loop slen
    
      
-- | Perform an efficient check on a string, to quickly determine if
-- the string is in a particular normalization format.
--
-- A 'Perhaps' result indicates that a more thorough check is
-- required, e.g. with 'isNormalized'.  The user may have to put the
-- string in its normalized form and compare the results.
quickCheck :: NormalizationMode -> Text -> NormalizationCheckResult
quickCheck mode t =
  unsafePerformIO . useAsPtr t $ \ptr len ->
    fmap toNCR . handleError $ unorm_quickCheck ptr (fromIntegral len)
                               (toNM mode)

-- | Indicate whether a string is in a given normalization form.
--
-- Unlike 'quickCheck', this function returns a definitive result.
-- For 'NFD', 'NFKD', and 'FCD' normalization forms, both functions
-- work in exactly the same ways.  For 'NFC' and 'NFKC' forms, where
-- 'quickCheck' may return 'Perhaps', this function will perform
-- further tests to arrive at a definitive result.
isNormalized :: NormalizationMode -> Text -> Bool
isNormalized mode t =
  unsafePerformIO . useAsPtr t $ \ptr len ->
    fmap asBool . handleError $ unorm_isNormalized ptr (fromIntegral len)
                                (toNM mode)

-- | Compare two strings for canonical equivalence.
-- Further options include case-insensitive comparison and
-- code point order (as opposed to code unit order).
--
-- Canonical equivalence between two strings is defined as their normalized
-- forms (NFD or NFC) being identical.
-- This function compares strings incrementally instead of normalizing
-- (and optionally case-folding) both strings entirely,
-- improving performance significantly.
--
-- Bulk normalization is only necessary if the strings do not fulfill the FCD
-- conditions. Only in this case, and only if the strings are relatively long,
-- is memory allocated temporarily.
-- For FCD strings and short non-FCD strings there is no memory allocation.
--
-- Options:
--
--  ['u_INPUT_IS_FCD'] Set if the caller knows that both strings fulfill the FCD conditions.
--     If not set, the function will 'quickCheck' for FCD
--     and normalize if necessary.
--
--  ['u_COMPARE_CODE_POINT_ORDER'] Set to choose code point order instead of code unit order.
--
--  ['u_COMPARE_IGNORE_CASE'] Set to compare strings case-insensitively using case folding,
--     instead of case-sensitively.
--     If set, then the following case folding options are used.
compare :: [CompareOption] -> Text -> Text -> Ordering
compare opts a b = unsafePerformIO .
  useAsPtr a $ \aptr alen ->
    useAsPtr b $ \bptr blen ->
      fmap asOrdering . handleError $
      unorm_compare aptr (fromIntegral alen) bptr (fromIntegral blen)
                    (foldCompareOptions opts)

foreign import ccall unsafe "unicode/unorm.h unorm_compare_4_0" unorm_compare
    :: Ptr UChar -> Int32 -> Ptr UChar -> Int32 -> Word32
    -> Ptr UErrorCode -> IO Int32

foreign import ccall unsafe "unicode/unorm.h unorm_quickCheck_4_0" unorm_quickCheck
    :: Ptr UChar -> Int32 -> UNormalizationMode -> Ptr UErrorCode
    -> IO UNormalizationCheckResult

foreign import ccall unsafe "unicode/unorm.h unorm_isNormalized_4_0" unorm_isNormalized
    :: Ptr UChar -> Int32 -> UNormalizationMode -> Ptr UErrorCode -> IO UBool

foreign import ccall unsafe "unicode/unorm.h unorm_normalize_4_0" unorm_normalize
    :: Ptr UChar -> Int32 -> UNormalizationMode -> Int32
    -> Ptr UChar -> Int32 -> Ptr UErrorCode -> IO Int32
