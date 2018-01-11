{-# LANGUAGE RankNTypes, MagicHash #-}

module FscqFs
  ( HT
  , initFscq
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC8
import qualified System.Directory
import Foreign.C.Error
import System.Posix.Types
import System.Posix.Files
import System.Posix.IO
import System.FilePath.Posix
import Word
import Disk
import Prog
import Fuse (defaultFuseOps,
             FuseOperations(..),
             FileStat(..),
             SyncType(..),
             EntryType(..),
             FileSystemStats(..))
import Data.IORef
import Interpreter as I
import qualified AsyncFS
import FSLayout
import qualified DirName
import Inode
import Control.Concurrent.MVar
import Text.Printf
import qualified System.Process
import qualified Data.List
import AsyncDisk
import Control.Monad
import qualified Errno
import ShowErrno
import qualified BFile
import System.Clock
import GenericFs
import Timings

-- Handle type for open files; we will use the inode number
type HT = Integer

verboseFuse :: Bool
verboseFuse = False

cachesize :: Integer
cachesize = 100000

debug :: String -> IO ()
debug msg =
  if verboseFuse then
    putStrLn msg
  else
    return ()

debugStart :: Show a => String -> a -> IO ()
debugStart op msg = debug $ op ++ ": " ++ (show msg)

debugMore :: Show a => a -> IO ()
debugMore msg = debug $ " .. " ++ (show msg)

-- File system configuration
nDataBitmaps :: Integer
nDataBitmaps = 1
nInodeBitmaps :: Integer
nInodeBitmaps = 1
nDescrBlocks :: Integer
nDescrBlocks = 64

elapsedTime :: TimeSpec -> IO String
elapsedTime start = do
  end <- getTime Monotonic
  let elapsedNanos = toNanoSecs $ diffTimeSpec start end
      elapsedMicros = (fromIntegral elapsedNanos)/1e3 :: Float in
    return $ show elapsedMicros ++ "us"

type MSCS = BFile.BFILE__Coq_memstate
type FSprog a = (MSCS -> Prog.Coq_prog (MSCS, a))
type FSrunner = forall a. FSprog a -> IO a
doFScall :: FscqState -> MVar MSCS -> FSrunner
doFScall ds ref f = do
  -- start <- getTime Monotonic
  s <- takeMVar ref
  (s', r) <- I.run ds $ f s
  putMVar ref s'
  -- elapsed <- elapsedTime start
  return r

initFscq :: String -> Bool -> IO (UserID, GroupID) -> IO Filesystem
initFscq disk_fn silent getIds = do
  fileExists <- System.Directory.doesFileExist disk_fn
  ds <- case disk_fn of
    "/tmp/crashlog.img" -> init_disk_crashlog disk_fn
    _ -> init_disk disk_fn
  fscqSt <- newFscqState ds
  (s, fsxp) <- if fileExists
  then
    do
      unless silent $ putStrLn $ "Recovering file system"
      res <- I.run fscqSt $ AsyncFS._AFS__recover cachesize
      case res of
        Errno.Err _ -> error $ "recovery failed; not an fscq fs?"
        Errno.OK (s, fsxp) -> do
          return (s, fsxp)
  else
    do
      unless silent $ putStrLn $ "Initializing file system"
      res <- I.run fscqSt $ AsyncFS._AFS__mkfs cachesize nDataBitmaps nInodeBitmaps nDescrBlocks
      case res of
        Errno.Err _ -> error $ "mkfs failed"
        Errno.OK (s, fsxp) -> do
          set_nblocks_disk ds $ fromIntegral $ coq_FSXPMaxBlock fsxp
          return (s, fsxp)
  unless silent $ putStrLn $ "Starting file system, " ++ (show $ coq_FSXPMaxBlock fsxp) ++ " blocks " ++ "magic " ++ (show $ coq_FSXPMagic fsxp)
  ref <- newMVar s
  m_fsxp <- newMVar fsxp
  return $ Filesystem (fscqFSOps getIds disk_fn ds (doFScall fscqSt ref) m_fsxp) (I.timings fscqSt)

-- See the HFuse API docs at:
-- https://hackage.haskell.org/package/HFuse-0.2.1/docs/System-Fuse.html
fscqFSOps :: IO (UserID, GroupID) -> String -> DiskState -> FSrunner -> MVar Coq_fs_xparams -> FuseOperations HT
fscqFSOps getIds fn ds fr m_fsxp = defaultFuseOps
  { fuseGetFileStat = fscqGetFileStat getIds fr m_fsxp
  , fuseOpen = fscqOpen fr m_fsxp
  , fuseCreateFile = fscqCreateFile fr m_fsxp
  , fuseCreateDevice = fscqCreate fr m_fsxp
  , fuseCreateDirectory = fscqCreateDir fr m_fsxp
  , fuseRemoveLink = fscqUnlink fr m_fsxp
  , fuseRemoveDirectory = fscqUnlink fr m_fsxp
  , fuseRead = fscqRead ds fr m_fsxp
  , fuseWrite = fscqWrite fr m_fsxp
  , fuseSetFileSize = fscqSetFileSize fr m_fsxp
  , fuseOpenDirectory = fscqOpenDirectory fr m_fsxp
  , fuseReadDirectory = fscqReadDirectory getIds fr m_fsxp
  , fuseGetFileSystemStats = fscqGetFileSystemStats fr m_fsxp
  , fuseDestroy = fscqDestroy ds fn fr m_fsxp
  , fuseSetFileTimes = fscqSetFileTimes
  , fuseRename = fscqRename fr m_fsxp
  , fuseSetFileMode = fscqChmod
  , fuseSynchronizeFile = fscqSyncFile fr m_fsxp
  , fuseSynchronizeDirectory = fscqSyncDir fr m_fsxp
  }

applyFlushgroup :: DiskState -> [(Integer, Coq_word)] -> IO ()
applyFlushgroup _ [] = return ()
applyFlushgroup ds ((a, v) : rest) = do
  applyFlushgroup ds rest
  write_disk ds a v

applyFlushgroups :: DiskState -> [[(Integer, Coq_word)]] -> IO ()
applyFlushgroups _ [] = return ()
applyFlushgroups ds (flushgroup : rest) = do
  applyFlushgroups ds rest
  applyFlushgroup ds flushgroup

materializeFlushgroups :: IORef Integer -> [[(Integer, Coq_word)]] -> IO ()
materializeFlushgroups idxref groups = do
  idx <- readIORef idxref
  writeIORef idxref (idx+1)
  _ <- System.Process.system $ printf "cp --sparse=always /tmp/crashlog.img /tmp/crashlog-%06d.img" idx
  ds <- init_disk $ printf "/tmp/crashlog-%06d.img" idx
  applyFlushgroups ds groups
  _ <- close_disk ds
  return ()

writeSubsets' :: [[(Integer, a)]] -> [[(Integer, a)]]
writeSubsets' [] = [[]]
writeSubsets' (heads : tails) =
    tailsubsets ++ (concat $ map (\ts -> map (\hd -> hd : ts) heads) tailsubsets)
  where
    tailsubsets = writeSubsets' tails

writeSubsets :: [(Integer, a)] -> [[(Integer, a)]]
writeSubsets writes = writeSubsets' addrWrites
  where
    addrWrites = Data.List.groupBy sameaddr writes
    sameaddr (x, _) (y, _) = (x == y)

materializeCrashes :: IORef Integer -> [[(Integer, Coq_word)]] -> IO ()
materializeCrashes idxref [] = materializeFlushgroups idxref []
materializeCrashes idxref (lastgroup : othergroups) = do
  materializeCrashes idxref othergroups
  mapM_ (\lastsubset -> materializeFlushgroups idxref (lastsubset : othergroups)) $ writeSubsets lastgroup


fscqDestroy :: DiskState -> String -> FSrunner -> MVar Coq_fs_xparams -> IO ()
fscqDestroy ds disk_fn fr m_fsxp  = withMVar m_fsxp $ \fsxp -> do
  _ <- fr $ AsyncFS._AFS__umount fsxp
  stats <- close_disk ds
  print_stats stats
  case disk_fn of
    "/tmp/crashlog.img" -> do
      flushgroups <- get_flush_log ds
      putStrLn $ "Number of flush groups: " ++ (show (length flushgroups))
      idxref <- newIORef 0
      materializeCrashes idxref flushgroups
    _ -> return ()

dirStat :: (UserID, GroupID) -> FileStat
dirStat (uid, gid) = FileStat
  { statEntryType = Directory
  , statFileMode = foldr1 unionFileModes
                     [ ownerReadMode, ownerWriteMode, ownerExecuteMode
                     , groupReadMode, groupExecuteMode
                     , otherReadMode, otherExecuteMode
                     ]
  , statLinkCount = 2
  , statFileOwner = uid
  , statFileGroup = gid
  , statSpecialDeviceID = 0
  , statFileSize = 4096
  , statBlocks = 1
  , statAccessTime = 0
  , statModificationTime = 0
  , statStatusChangeTime = 0
  }

attrToType :: INODE__Coq_iattr -> EntryType
attrToType attr =
  if t == 0 then RegularFile else Socket
  where t = wordToNat 32 $ _INODE__coq_AType attr

fileStat :: (UserID, GroupID) -> INODE__Coq_iattr -> FileStat
fileStat (uid, gid) attr = FileStat
  { statEntryType = attrToType attr
  , statFileMode = foldr1 unionFileModes
                     [ ownerReadMode, ownerWriteMode, ownerExecuteMode
                     , groupReadMode, groupWriteMode, groupExecuteMode
                     , otherReadMode, otherWriteMode, otherExecuteMode
                     ]
  , statLinkCount = 1
  , statFileOwner = uid
  , statFileGroup = gid
  , statSpecialDeviceID = 0
  , statFileSize = fromIntegral $ wordToNat 64 $ _INODE__coq_ABytes attr
  , statBlocks = 1
  , statAccessTime = 0
  , statModificationTime = fromIntegral $ wordToNat 32 $ _INODE__coq_AMTime attr
  , statStatusChangeTime = 0
  }

fscqGetFileStat :: IO (UserID, GroupID) -> FSrunner -> MVar Coq_fs_xparams -> FilePath -> IO (Either Errno FileStat)
fscqGetFileStat getIds fr m_fsxp (_:path)
  | (path == "sync") = withMVar m_fsxp $ \fsxp -> do
    ctx <- getIds
    _ <- fr $ AsyncFS._AFS__umount fsxp
    return $ Right $ fileStat ctx $ _INODE__iattr_upd _INODE__iattr0 $ INODE__UBytes $ W 4096
  | path == "stats" = do
    ctx <- getIds
    return $ Right $ fileStat ctx $ _INODE__iattr_upd _INODE__iattr0 $ INODE__UBytes $ W 4096
  | otherwise = withMVar m_fsxp $ \fsxp -> do
  debugStart "STAT" path
  nameparts <- return $ splitDirectories path
  (r, ()) <- fr $ AsyncFS._AFS__lookup fsxp (coq_FSXPRootInum fsxp) nameparts
  debugMore r
  case r of
    Errno.Err e -> return $ Left $ errnoToPosix e
    Errno.OK (inum, isdir)
      | isdir -> do
        ctx <- getIds
        return $ Right $ dirStat ctx
      | otherwise -> do
        (attr, ()) <- fr $ AsyncFS._AFS__file_get_attr fsxp inum
        ctx <- getIds
        return $ Right $ fileStat ctx attr
fscqGetFileStat _ _ _ _ = return $ Left eNOENT

fscqOpenDirectory :: FSrunner -> MVar Coq_fs_xparams -> FilePath -> IO (Either Errno HT)
fscqOpenDirectory fr m_fsxp (_:path) = withMVar m_fsxp $ \fsxp -> do
  debugStart "OPENDIR" path
  nameparts <- return $ splitDirectories path
  (r, ()) <- fr $ AsyncFS._AFS__lookup fsxp (coq_FSXPRootInum fsxp) nameparts
  debugMore r
  case r of
    Errno.Err e -> return $ Left $ errnoToPosix e
    Errno.OK (inum, isdir)
      | isdir -> return $ Right inum
      | otherwise -> return $ Left eNOTDIR
fscqOpenDirectory _ _ "" = return $ Left eNOENT

fscqReadDirectory :: IO (UserID, GroupID) -> FSrunner -> MVar Coq_fs_xparams -> FilePath -> HT -> IO (Either Errno [(FilePath, FileStat)])
fscqReadDirectory getIds fr m_fsxp _ dnum = withMVar m_fsxp $ \fsxp -> do
  debugStart "READDIR" dnum
  ctx <- getIds
  (files, ()) <- fr $ AsyncFS._AFS__readdir fsxp dnum
  files_stat <- mapM (mkstat fsxp ctx) files
  return $ Right $ [(".",          dirStat ctx)
                   ,("..",         dirStat ctx)
                   ] ++ files_stat
  where
    mkstat fsxp ctx (fn, (inum, isdir))
      | isdir = return $ (fn, dirStat ctx)
      | otherwise = do
        (attr, ()) <- fr $ AsyncFS._AFS__file_get_attr fsxp inum
        return $ (fn, fileStat ctx attr)

fscqOpen :: FSrunner -> MVar Coq_fs_xparams -> FilePath -> OpenMode -> OpenFileFlags -> IO (Either Errno HT)
fscqOpen fr m_fsxp (_:path) _ flags
  | (path == "stats") || (path == "sync") = return $ Right 0
  | otherwise = withMVar m_fsxp $ \fsxp -> do
  debugStart "OPEN" path
  nameparts <- return $ splitDirectories path
  (r, ()) <- fr $ AsyncFS._AFS__lookup fsxp (coq_FSXPRootInum fsxp) nameparts
  debugMore r
  case r of
    Errno.Err e -> return $ Left $ errnoToPosix e
    Errno.OK (inum, isdir)
      | isdir -> return $ Left eISDIR
      | otherwise -> do
        if trunc flags then do
          _ <- fr $ AsyncFS._AFS__file_truncate fsxp inum 0
          (ok, ()) <- fr $ AsyncFS._AFS__file_set_sz fsxp inum (W64 0)
          case ok of
            Errno.OK _ -> return $ Right inum
            Errno.Err e -> return $ Left $ errnoToPosix e
        else do
          return $ Right inum
fscqOpen _ _ _ _ _ = return $ Left eIO

splitDirsFile :: String -> ([String], String)
splitDirsFile path = (init parts, last parts)
  where parts = splitDirectories path

fscqCreateFile :: FSrunner -> MVar Coq_fs_xparams -> FilePath -> FileMode -> OpenMode -> OpenFileFlags -> IO (Either Errno HT)
fscqCreateFile fr m_fsxp (_:path) _ _ _
  | (path == "stats") || (path == "sync") = return $ Left eEXIST
  | otherwise = withMVar m_fsxp $ \fsxp -> do
  debugStart "CREATEFILE" path
  (dirparts, filename) <- return $ splitDirsFile path
  (rd, ()) <- fr $ AsyncFS._AFS__lookup fsxp (coq_FSXPRootInum fsxp) dirparts
  debugMore rd
  case rd of
    Errno.Err e -> return $ Left $ errnoToPosix e
    Errno.OK (dnum, isdir)
      | isdir -> do
        (r, ()) <- fr $ AsyncFS._AFS__create fsxp dnum filename
        debugMore r
        case r of
          Errno.Err e -> return $ Left $ errnoToPosix e
          Errno.OK inum -> return $ Right inum
      | otherwise -> return $ Left eNOTDIR
fscqCreateFile _ _ _ _ _ _ = return $ Left eOPNOTSUPP

fscqCreate :: FSrunner -> MVar Coq_fs_xparams -> FilePath -> EntryType -> FileMode -> DeviceID -> IO Errno
fscqCreate fr m_fsxp (_:path) entrytype _ _ = withMVar m_fsxp $ \fsxp -> do
  debugStart "CREATE" path
  (dirparts, filename) <- return $ splitDirsFile path
  (rd, ()) <- fr $ AsyncFS._AFS__lookup fsxp (coq_FSXPRootInum fsxp) dirparts
  debugMore rd
  case rd of
    Errno.Err e -> return $ errnoToPosix e
    Errno.OK (dnum, isdir)
      | isdir -> do
        (r, ()) <- case entrytype of
          RegularFile -> fr $ AsyncFS._AFS__create fsxp dnum filename
          Socket -> fr $ AsyncFS._AFS__mksock fsxp dnum filename
          _ -> return (Errno.Err Errno.EINVAL, ())
        debugMore r
        case r of
          Errno.Err e -> return $ errnoToPosix e
          Errno.OK _ -> return eOK
      | otherwise -> return eNOTDIR
fscqCreate _ _ _ _ _ _ = return eOPNOTSUPP

fscqCreateDir :: FSrunner -> MVar Coq_fs_xparams -> FilePath -> FileMode -> IO Errno
fscqCreateDir fr m_fsxp (_:path) _ = withMVar m_fsxp $ \fsxp -> do
  debugStart "MKDIR" path
  (dirparts, filename) <- return $ splitDirsFile path
  (rd, ()) <- fr $ AsyncFS._AFS__lookup fsxp (coq_FSXPRootInum fsxp) dirparts
  debugMore rd
  case rd of
    Errno.Err e -> return $ errnoToPosix e
    Errno.OK (dnum, isdir)
      | isdir -> do
        (r, ()) <- fr $ AsyncFS._AFS__mkdir fsxp dnum filename
        debugMore r
        case r of
          Errno.Err e -> return $ errnoToPosix e
          Errno.OK _ -> return eOK
      | otherwise -> return eNOTDIR
fscqCreateDir _ _ _ _ = return eOPNOTSUPP

fscqUnlink :: FSrunner -> MVar Coq_fs_xparams -> FilePath -> IO Errno
fscqUnlink fr m_fsxp (_:path) = withMVar m_fsxp $ \fsxp -> do
  debugStart "UNLINK" path
  (dirparts, filename) <- return $ splitDirsFile path
  (rd, ()) <- fr $ AsyncFS._AFS__lookup fsxp (coq_FSXPRootInum fsxp) dirparts
  debugMore rd
  case rd of
    Errno.Err e -> return $ errnoToPosix e
    Errno.OK (dnum, isdir)
      | isdir -> do
        (r, ()) <- fr $ AsyncFS._AFS__delete fsxp dnum filename
        debugMore r
        case r of
          Errno.OK _ -> return eOK
          Errno.Err e -> return $ errnoToPosix e
      | otherwise -> return eNOTDIR
fscqUnlink _ _ _ = return eOPNOTSUPP

-- Wrappers for converting Coq_word to/from ByteString, with
-- the help of i2buf and buf2i from hslib/Disk.
blocksize :: Integer
blocksize = _Valulen__valulen `div` 8

data BlockRange =
  BR !Integer !Integer !Integer   -- blocknumber, offset-in-block, count-from-offset

compute_ranges_int :: Integer -> Integer -> [BlockRange]
compute_ranges_int off count = map mkrange $ zip3 blocknums startoffs endoffs
  where
    mkrange (blk, startoff, endoff) = BR blk startoff (endoff-startoff)
    blocknums = [off `div` blocksize .. (off + count - 1) `div` blocksize]
    startoffs = [off `mod` blocksize] ++ replicate (length blocknums - 1) 0
    endoffs = replicate (length blocknums - 1) blocksize ++ [(off + count - 1) `mod` blocksize + 1]

compute_ranges :: FileOffset -> ByteCount -> [BlockRange]
compute_ranges off count =
  compute_ranges_int (fromIntegral off) (fromIntegral count)

fscqRead :: DiskState -> FSrunner -> MVar Coq_fs_xparams -> FilePath -> HT -> ByteCount -> FileOffset -> IO (Either Errno BS.ByteString)
fscqRead ds fr m_fsxp (_:path) inum byteCount offset
  | path == "stats" = do
    Stats r w s <- get_stats ds
    clear_stats ds
    statbuf <- return $ BSC8.pack $
      "Reads:  " ++ (show r) ++ "\n" ++
      "Writes: " ++ (show w) ++ "\n" ++
      "Syncs:  " ++ (show s) ++ "\n"
    return $ Right statbuf
  | otherwise = withMVar m_fsxp $ \fsxp -> do
  (wlen, ()) <- fr $ AsyncFS._AFS__file_get_sz fsxp inum
  len <- return $ fromIntegral $ wordToNat 64 wlen
  offset' <- return $ min offset len
  byteCount' <- return $ min byteCount $ (fromIntegral len) - (fromIntegral offset')
  pieces <- mapM (read_piece fsxp) $ compute_ranges offset' byteCount'
  return $ Right $ BS.concat pieces

  where
    read_piece fsxp (BR blk off count) = do
      (wbuf, ()) <- fr $ AsyncFS._AFS__read_fblock fsxp inum blk
      return $ BS.take (fromIntegral count) $ BS.drop (fromIntegral off) $ w2bs wbuf 4096

fscqRead _ _ _ [] _ _ _ = do
  return $ Left $ eIO

compute_range_pieces :: FileOffset -> BS.ByteString -> [(BlockRange, BS.ByteString)]
compute_range_pieces off buf = zip ranges pieces
  where
    ranges = compute_ranges_int (fromIntegral off) $ fromIntegral $ BS.length buf
    pieces = map getpiece ranges
    getpiece (BR blk boff bcount) = BS.take (fromIntegral bcount) $ BS.drop (fromIntegral bufoff) buf
      where bufoff = (blk * blocksize) + boff - (fromIntegral off)

data WriteState =
   WriteOK !ByteCount
 | WriteErr !ByteCount

fscqWrite :: FSrunner -> MVar Coq_fs_xparams -> FilePath -> HT -> BS.ByteString -> FileOffset -> IO (Either Errno ByteCount)
fscqWrite fr m_fsxp _ inum bs offset = withMVar m_fsxp $ \fsxp -> do
  (wlen, ()) <- fr $ AsyncFS._AFS__file_get_sz fsxp inum
  len <- return $ fromIntegral $ wordToNat 64 wlen
  endpos <- return $ (fromIntegral offset) + (fromIntegral (BS.length bs))
  (okspc, do_log) <- if len < endpos then do
    (ok, _) <- fr $ AsyncFS._AFS__file_truncate fsxp inum ((endpos + 4095) `div` 4096)
    return (ok, True)
  else do
    bslen <- return $ fromIntegral $ BS.length bs
    if ((fromIntegral offset) `mod` 4096 == 0) && (bslen `mod` 4096 == 0) && bslen > 4096 * 5 then
      -- block is large and aligned -> bypass write
      return $ (Errno.OK (), False)
    else
      return $ (Errno.OK (), True)
  case okspc of
    Errno.OK _ -> do
      r <- foldM (write_piece do_log fsxp len) (WriteOK 0) (compute_range_pieces offset bs)
      case r of
        WriteOK c -> do
          okspc2 <- if len < endpos then do
            (ok, _) <- fr $ AsyncFS._AFS__file_set_sz fsxp inum (W endpos)
            return ok
          else
            return $ (Errno.OK ())
          case okspc2 of
            Errno.OK _ -> return $ Right c
            Errno.Err _ -> return $ Left eNOSPC
        WriteErr c ->
          if c == 0 then
            return $ Left eIO
          else
            return $ Right c
    Errno.Err e -> do
      return $ Left $ errnoToPosix e
  where
    write_piece _ _ _ (WriteErr c) _ = return $ WriteErr c
    write_piece do_log fsxp init_len (WriteOK c) (BR blk off cnt, piece_bs) = do
      new_bs <- if cnt == blocksize then
          -- Whole block writes don't need read-modify-write
          return piece_bs
        else do
          old_bs <- if (init_len <= blk*blocksize) || (off == 0 && init_len <= blk*blocksize + cnt) then
              -- If we are doing a partial block write, we don't need RMW in two cases:
              -- (1.) The file was smaller than the start of this block.
              -- (2.) The partial write of this block starts immediately at offset 0
              --      in this block, and writes all the way up to (and maybe past)
              --      the original end of the file.
              return $ BS.replicate (fromIntegral blocksize) 0
            else do
              (block, ()) <- fr $ AsyncFS._AFS__read_fblock fsxp inum blk
              case block of
                W w -> i2bs w 4096
                WBS bs' -> return bs'
          return $ BS.append (BS.take (fromIntegral off) old_bs)
                 $ BS.append piece_bs
                 $ BS.drop (fromIntegral $ off + cnt) old_bs
      if do_log then do
        _ <- fr $ AsyncFS._AFS__update_fblock fsxp inum blk (WBS new_bs)
        return ()
      else do
        _ <- fr $ AsyncFS._AFS__update_fblock_d fsxp inum blk (WBS new_bs)
        return ()
      return $ WriteOK (c + (fromIntegral cnt))

fscqSetFileSize :: FSrunner -> MVar Coq_fs_xparams -> FilePath -> FileOffset -> IO Errno
fscqSetFileSize fr m_fsxp (_:path) size = withMVar m_fsxp $ \fsxp -> do
  debugStart "SETSIZE" (path, size)
  nameparts <- return $ splitDirectories path
  (r, ()) <- fr $ AsyncFS._AFS__lookup fsxp (coq_FSXPRootInum fsxp) nameparts
  debugMore r
  case r of
    Errno.Err e -> return $ errnoToPosix e
    Errno.OK (inum, isdir)
      | isdir -> return eISDIR
      | otherwise -> do
        (ok, ()) <- fr $ AsyncFS._AFS__file_set_sz fsxp inum (W64 $ fromIntegral size)
        case ok of
          Errno.OK _ -> return eOK
          Errno.Err e -> return $ errnoToPosix e
fscqSetFileSize _ _ _ _ = return eIO

fscqGetFileSystemStats :: FSrunner -> MVar Coq_fs_xparams -> String -> IO (Either Errno FileSystemStats)
fscqGetFileSystemStats fr m_fsxp _ = withMVar m_fsxp $ \fsxp -> do
  (freeblocks, (freeinodes, ())) <- fr $ AsyncFS._AFS__statfs fsxp
  block_bitmaps <- return $ coq_BmapNBlocks $ coq_FSXPBlockAlloc1 fsxp
  inode_bitmaps <- return $ coq_BmapNBlocks $ coq_FSXPInodeAlloc fsxp
  return $ Right $ FileSystemStats
    { fsStatBlockSize = 4096
    , fsStatBlockCount = 8 * 4096 * (fromIntegral $ block_bitmaps)
    , fsStatBlocksFree = fromIntegral $ freeblocks
    , fsStatBlocksAvailable = fromIntegral $ freeblocks
    , fsStatFileCount = 8 * 4096 * (fromIntegral $ inode_bitmaps)
    , fsStatFilesFree = fromIntegral $ freeinodes
    , fsStatMaxNameLength = fromIntegral DirName._SDIR__namelen
    }

fscqSetFileTimes :: FilePath -> EpochTime -> EpochTime -> IO Errno
fscqSetFileTimes _ _ _ = do
  return eOK

fscqRename :: FSrunner -> MVar Coq_fs_xparams -> FilePath -> FilePath -> IO Errno
fscqRename fr m_fsxp (_:src) (_:dst) = withMVar m_fsxp $ \fsxp -> do
  debugStart "RENAME" (src, dst)
  (srcparts, srcname) <- return $ splitDirsFile src
  (dstparts, dstname) <- return $ splitDirsFile dst
  (r, ()) <- fr $ AsyncFS._AFS__rename fsxp (coq_FSXPRootInum fsxp) srcparts srcname dstparts dstname
  debugMore r
  case r of
    Errno.OK _ -> return eOK
    Errno.Err e -> return $ errnoToPosix e
fscqRename _ _ _ _ = return eIO

fscqChmod :: FilePath -> FileMode -> IO Errno
fscqChmod _ _ = do
  return eOK

fscqSyncFile :: FSrunner -> MVar Coq_fs_xparams -> FilePath -> HT -> SyncType -> IO Errno
fscqSyncFile fr m_fsxp _ inum syncType = withMVar m_fsxp $ \fsxp -> do
  debugStart "SYNC FILE" inum
  _ <- fr $ AsyncFS._AFS__file_sync fsxp inum
  case syncType of
    DataSync -> return eOK
    FullSync -> do
      _ <- fr $ AsyncFS._AFS__tree_sync fsxp
      return eOK

fscqSyncDir :: FSrunner -> MVar Coq_fs_xparams -> FilePath -> HT -> SyncType -> IO Errno
fscqSyncDir fr m_fsxp _ inum _ = withMVar m_fsxp $ \fsxp -> do
  debugStart "SYNC DIR" inum
  _ <- fr $ AsyncFS._AFS__tree_sync fsxp
  return eOK