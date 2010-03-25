{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | Command line tool for mounting a halfs filesystem from userspace via
-- hFUSE/FUSE.

module Main
where

import Control.Applicative
import Control.Exception     (assert)
import Data.Array.IO         (IOUArray)
import Data.Bits
import Data.IORef            (IORef)
import Data.Word             
import System.Console.GetOpt 
import System.Directory      (doesFileExist)
import System.Environment
import System.IO hiding      (openFile)
import System.Posix.Types    ( ByteCount
                             , DeviceID
                             , EpochTime
                             , FileMode
                             , FileOffset
                             , GroupID
                             , UserID
                             )
import System.Posix.User     (getRealUserID, getRealGroupID)
import System.Fuse     

import Halfs.Classes
import Halfs.CoreAPI
import Halfs.File (FileHandle)
import Halfs.Errors
import Halfs.HalfsState
import Halfs.Monad
import Halfs.Utils
import System.Device.BlockDevice
import System.Device.File
import System.Device.Memory
import Tests.Utils

import qualified Data.ByteString  as BS
import qualified Data.Map         as M
import qualified Halfs.Protection as HP
import qualified Halfs.Types      as H
import qualified Prelude
import Prelude hiding (catch, log, read)

-- Halfs-specific stuff we carry around in our FUSE functions; note that the
-- FUSE library does this via opaque ptr to user data, but since hFUSE
-- reimplements fuse_main and doesn't seem to provide a way to hang onto
-- private data, we just carry the data ourselves.

type Logger m              = String -> m ()
data HalfsSpecific b r l m = HS {
    hspLogger  :: Logger m
  , hspState   :: HalfsState b r l m
    -- ^ The filesystem state, as provided by CoreAPI.mount.
  , hspFpdhMap :: H.LockedRscRef l r (M.Map FilePath (H.DirHandle r l))
    -- ^ Tracks DirHandles across halfs{Open,Read,Release}Directory invocations;
    -- we should be able to do this via HFuse and the fuse_file_info* out
    -- parameter for the 'open' fuse operation, but the binding doesn't support
    -- this.  However, we'd probably still need something persistent here to go
    -- from the opaque handle we stored in the fuse_file_info struct to one of
    -- our DirHandles.
  }

-- This isn't a halfs limit, but we have to pick something for FUSE.
maxNameLength :: Integer
maxNameLength = 32768

main :: IO ()
main = do
  (opts, argv1) <- do
    argv0 <- getArgs
    case getOpt RequireOrder options argv0 of
      (o, n, [])   -> return (foldl (flip ($)) defOpts o, n)
      (_, _, errs) -> ioError $ userError $ concat errs ++ usageInfo hdr options
        where hdr = "Usage: halfs [OPTION...] <FUSE CMDLINE>"

  let sz = optSecSize opts; n = optNumSecs opts
  (exists, dev) <- maybe (fail "Unable to create device") return
    =<<
    let wb = (liftM . liftM) . (,) in
    if optMemDev opts
     then wb False $ newMemoryBlockDevice n sz <* putStrLn "Created new memdev."
     else case optFileDev opts of
            Nothing -> fail "Can't happen"
            Just fp -> do
              exists <- doesFileExist fp
              wb exists $ 
                if exists
                 then newFileBlockDevice fp sz 
                        <* putStrLn "Created filedev from existing file."
                 else withFileStore False fp sz n (`newFileBlockDevice` sz)
                        <* putStrLn "Created filedev from new file."  

  uid <- (HP.UID . fromIntegral) `fmap` getRealUserID
  gid <- (HP.GID . fromIntegral) `fmap` getRealGroupID

  when (not exists) $ do
    exec $ newfs dev uid gid $
      H.FileMode
        [H.Read, H.Write, H.Execute]
        [H.Read,          H.Execute]
        [                          ]
    return ()

  fs <- exec $ mount dev uid gid

  System.IO.withFile (optLogFile opts) WriteMode $ \h -> do

  let log s = hPutStrLn h s >> hFlush h
  dhMap <- newLockedRscRef M.empty
  withArgs argv1 $ fuseMain (ops (HS log fs dhMap)) $ \e -> do
    log $ "*** Exception: " ++ show e
    return eFAULT

--------------------------------------------------------------------------------
-- Halfs-hFUSE filesystem operation implementation

-- JS: ST monad impls will have to get mapped to hFUSE ops via stToIO?

ops :: HalfsSpecific (IOUArray Word64 Bool) IORef IOLock IO
    -> FuseOperations FileHandle
ops hsp = FuseOperations
  { fuseGetFileStat          = halfsGetFileStat          hsp
  , fuseReadSymbolicLink     = halfsReadSymbolicLink     hsp
  , fuseCreateDevice         = halfsCreateDevice         hsp
  , fuseCreateDirectory      = halfsCreateDirectory      hsp
  , fuseRemoveLink           = halfsRemoveLink           hsp
  , fuseRemoveDirectory      = halfsRemoveDirectory      hsp
  , fuseCreateSymbolicLink   = halfsCreateSymbolicLink   hsp
  , fuseRename               = halfsRename               hsp
  , fuseCreateLink           = halfsCreateLink           hsp
  , fuseSetFileMode          = halfsSetFileMode          hsp
  , fuseSetOwnerAndGroup     = halfsSetOwnerAndGroup     hsp
  , fuseSetFileSize          = halfsSetFileSize          hsp
  , fuseSetFileTimes         = halfsSetFileTimes         hsp
  , fuseOpen                 = halfsOpen                 hsp
  , fuseRead                 = halfsRead                 hsp
  , fuseWrite                = halfsWrite                hsp
  , fuseGetFileSystemStats   = halfsGetFileSystemStats   hsp
  , fuseFlush                = halfsFlush                hsp
  , fuseRelease              = halfsRelease              hsp
  , fuseSynchronizeFile      = halfsSynchronizeFile      hsp
  , fuseOpenDirectory        = halfsOpenDirectory        hsp
  , fuseReadDirectory        = halfsReadDirectory        hsp
  , fuseReleaseDirectory     = halfsReleaseDirectory     hsp
  , fuseSynchronizeDirectory = halfsSynchronizeDirectory hsp
  , fuseAccess               = halfsAccess               hsp
  , fuseInit                 = halfsInit                 hsp
  , fuseDestroy              = halfsDestroy              hsp
  }

halfsGetFileStat :: HalfsCapable b t r l m =>
                    HalfsSpecific b r l m
                 -> FilePath
                 -> m (Either Errno FileStat)
halfsGetFileStat (HS log fs _fpdhMap) fp = do
  log $ "halfsGetFileStat: fp = " ++ show fp
  eestat <- execOrErrno eINVAL id (fstat fs fp)
  case eestat of
    Left en -> do
      log $ "  (fstat failed w/ " ++ show en ++ ")"
      return $ Left en
    Right stat -> 
      Right `fmap` hfstat2fstat stat

halfsReadSymbolicLink :: HalfsCapable b t r l m =>
                         HalfsSpecific b r l m
                      -> FilePath
                      -> m (Either Errno FilePath)
halfsReadSymbolicLink (HS _log _fs _fpdhMap) _fp = do 
  error "halfsReadSymbolicLink: Not Yet Implemented" -- TODO
  return (Left eNOSYS)

halfsCreateDevice :: HalfsCapable b t r l m =>
                     HalfsSpecific b r l m
                  -> FilePath -> EntryType -> FileMode -> DeviceID
                  -> m Errno
halfsCreateDevice (HS log fs _fpdhMap) fp etype mode _devID = do
  log $ "halfsCreateDevice: fp = " ++ show fp ++ ", etype = " ++ show etype ++
        ", mode = " ++ show mode
  case etype of
    RegularFile -> do
      log $ "halfsCreateDevice: Regular file w/ " ++ show hmode
      execToErrno eINVAL (const eOK) $ 
        createFile (withLogger log fs) fp hmode
    _ -> do
      log $ "halfsCreateDevice: Error: Unsupported EntryType encountered."
      return eINVAL
  where hmode = mode2hmode mode

halfsCreateDirectory :: HalfsCapable b t r l m =>
                        HalfsSpecific b r l m
                     -> FilePath -> FileMode
                     -> m Errno
halfsCreateDirectory (HS _log _fs _fpdhMap) _fp _mode = do
  error "halfsCreateDirectory: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsRemoveLink :: HalfsCapable b t r l m =>
                   HalfsSpecific b r l m
                -> FilePath
                -> m Errno
halfsRemoveLink (HS _log _fs _fpdhMap) _fp = do
  error "halfsRemoveLink: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsRemoveDirectory :: HalfsCapable b t r l m =>
                        HalfsSpecific b r l m
                     -> FilePath
                     -> m Errno
halfsRemoveDirectory (HS _log _fs _fpdhMap) _fp = do
  error "halfsRemoveDirectory: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsCreateSymbolicLink :: HalfsCapable b t r l m =>
                           HalfsSpecific b r l m
                        -> FilePath -> FilePath
                        -> m Errno
halfsCreateSymbolicLink (HS _log _fs _fpdhMap) _src _dst = do
  error $ "halfsCreateSymbolicLink: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsRename :: HalfsCapable b t r l m =>
               HalfsSpecific b r l m
            -> FilePath -> FilePath
            -> m Errno
halfsRename (HS _log _fs _fpdhMap) _old _new = do
  error $ "halfsRename: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsCreateLink :: HalfsCapable b t r l m =>
                   HalfsSpecific b r l m
                -> FilePath -> FilePath
                -> m Errno
halfsCreateLink (HS _log _fs _fpdhMap) _src _dst = do
  error $ "halfsCreateLink: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsSetFileMode :: HalfsCapable b t r l m =>
                    HalfsSpecific b r l m
                 -> FilePath -> FileMode
                 -> m Errno
halfsSetFileMode (HS _log _fs _fpdhMap) _fp _mode = do
  error $ "halfsSetFileMode: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsSetOwnerAndGroup :: HalfsCapable b t r l m =>
                         HalfsSpecific b r l m
                      -> FilePath -> UserID -> GroupID
                      -> m Errno
halfsSetOwnerAndGroup (HS _log _fs _fpdhMap) _fp _uid _gid = do
  error $ "halfsSetOwnerAndGroup: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsSetFileSize :: HalfsCapable b t r l m =>
                    HalfsSpecific b r l m
                 -> FilePath -> FileOffset
                 -> m Errno
halfsSetFileSize (HS log fs _fpdhMap) fp offset = do
  log $ "halfsSetFileSize: setting " ++ show fp ++ " to size " ++ show offset
  execToErrno eINVAL (const eOK) $ setFileSize fs fp (fromIntegral offset)
         
halfsSetFileTimes :: HalfsCapable b t r l m =>
                     HalfsSpecific b r l m
                  -> FilePath -> EpochTime -> EpochTime
                  -> m Errno
halfsSetFileTimes (HS log fs _fpdhMap) fp accTm modTm = do
  -- TODO: Check perms: caller must be file owner w/ write access or
  -- superuser.
  log $ "halfsSetFileTimes: fp = " ++ show fp
  accTm' <- fromCTime accTm
  modTm' <- fromCTime modTm
  execToErrno eINVAL (const eOK) $
    setFileTimes fs fp accTm' modTm'     
         
halfsOpen :: HalfsCapable b t r l m =>
             HalfsSpecific b r l m             
          -> FilePath -> OpenMode -> OpenFileFlags
          -> m (Either Errno FileHandle)
halfsOpen (HS log fs _fpdhMap) fp omode flags = do
  log $ "halfsOpen: fp = " ++ show fp ++ ", omode = " ++ show omode ++ 
        ", flags = " ++ show flags
  rslt <- execOrErrno eINVAL id $ openFile fs fp halfsFlags
  log $ "halfsOpen: CoreAPI.openFile completed: rslt = " ++ show rslt
  return rslt
  where
    -- NB: In HFuse 0.2.2, the explicit and truncate are always false,
    -- so we do not pass them down to halfs.  Similarly, halfs does not
    -- support noctty, so it's ignored here as well.
    halfsFlags = H.FileOpenFlags
      { H.append   = append flags
      , H.nonBlock = nonBlock flags
      , H.openMode = case omode of
          ReadOnly  -> H.ReadOnly
          WriteOnly -> H.WriteOnly
          ReadWrite -> H.ReadWrite
      }

halfsRead :: HalfsCapable b t r l m =>
             HalfsSpecific b r l m
          -> FilePath -> FileHandle -> ByteCount -> FileOffset
          -> m (Either Errno BS.ByteString)
halfsRead (HS log fs _fpdhMap) fp fh byteCnt offset = do
  log $ "halfsRead: Reading " ++ show byteCnt ++ " bytes from " ++
        show fp ++ " at offset " ++ show offset
  execOrErrno eINVAL id $ 
    read fs fh (fromIntegral offset) (fromIntegral byteCnt)

halfsWrite :: HalfsCapable b t r l m =>
              HalfsSpecific b r l m
           -> FilePath -> FileHandle -> BS.ByteString -> FileOffset
           -> m (Either Errno ByteCount)
halfsWrite (HS log fs _fpdhMap) fp fh bytes offset = do
  log $ "halfsWrite: Writing " ++ show (BS.length bytes) ++ " bytes to " ++ 
        show fp ++ " at offset " ++ show offset
  execOrErrno eINVAL id $ do
    write fs fh (fromIntegral offset) bytes
    return (fromIntegral $ BS.length bytes)

halfsGetFileSystemStats :: HalfsCapable b t r l m =>
                           HalfsSpecific b r l m
                        -> FilePath
                        -> m (Either Errno System.Fuse.FileSystemStats)
halfsGetFileSystemStats (HS _log fs _fpdhMap) _fp = do
  execOrErrno eINVAL fss2fss (fsstat fs)
  where
    fss2fss (FSS bs bc bf ba fc ff fa) = System.Fuse.FileSystemStats
      { fsStatBlockSize     = bs
      , fsStatBlockCount    = bc
      , fsStatBlocksFree    = bf
      , fsStatBlocksAvail   = ba
      , fsStatFileCount     = fc
      , fsStatFilesFree     = ff
      , fsStatFilesAvail    = fa
      , fsStatMaxNameLength = maxNameLength
      }

halfsFlush :: HalfsCapable b t r l m =>
              HalfsSpecific b r l m
           -> FilePath -> FileHandle
           -> m Errno
halfsFlush (HS log fs _fpdhMap) fp fh = do
  log $ "halfsFlush: Flushing " ++ show fp
  execToErrno eINVAL (const eOK) $ flush fs fh
         
halfsRelease :: HalfsCapable b t r l m =>
                HalfsSpecific b r l m
             -> FilePath -> FileHandle
             -> m ()
halfsRelease (HS log fs _fpdhMap) fp fh = do
  log $ "halfsRelease: Releasing " ++ show fp
  _ <- execOrErrno eINVAL (const eOK) $ closeFile fs fh
  return () 
         
halfsSynchronizeFile :: HalfsCapable b t r l m =>
                        HalfsSpecific b r l m
                     -> FilePath -> System.Fuse.SyncType
                     -> m Errno
halfsSynchronizeFile (HS _log _fs _fpdhMap) _fp _syncType = do
  error "halfsSynchronizeFile: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsOpenDirectory :: HalfsCapable b t r l m =>
                      HalfsSpecific b r l m
                   -> FilePath
                   -> m Errno
halfsOpenDirectory (HS log fs fpdhMap) fp = do
  log $ "halfsOpenDirectory: fp = " ++ show fp
  execToErrno eINVAL (const eOK) $ 
    withLockedRscRef fpdhMap $ \ref -> do
      mdh <- lookupRM fp ref
      case mdh of
        Nothing -> openDir fs fp >>= modifyRef ref . M.insert fp 
        _       -> return ()
  
halfsReadDirectory :: HalfsCapable b t r l m =>  
                      HalfsSpecific b r l m
                   -> FilePath
                   -> m (Either Errno [(FilePath, FileStat)])
halfsReadDirectory (HS log fs fpdhMap) fp = do
  log $ "halfsReadDirectory: fp = " ++ show fp
  rslt <- execOrErrno eINVAL id $ 
    withLockedRscRef fpdhMap $ \ref -> do
      mdh <- lookupRM fp ref
      case mdh of
        Nothing -> throwError HE_DirectoryHandleNotFound
        Just dh -> readDir fs dh
                     >>= mapM (\(p, s) -> (,) p `fmap` hfstat2fstat s)
  log $ "  rslt = " ++ show rslt
  return rslt

halfsReleaseDirectory :: HalfsCapable b t r l m =>
                         HalfsSpecific b r l m
                      -> FilePath
                      -> m Errno
halfsReleaseDirectory (HS log fs fpdhMap) fp = do
  log $ "halfsReleaseDirectory: fp = " ++ show fp
  execToErrno eINVAL (const eOK) $
    withLockedRscRef fpdhMap $ \ref -> do
      mdh <- lookupRM fp ref
      case mdh of
        Nothing -> throwError HE_DirectoryHandleNotFound
        Just dh -> closeDir fs dh >> modifyRef ref (M.delete fp)
         
halfsSynchronizeDirectory :: HalfsCapable b t r l m =>
                             HalfsSpecific b r l m
                          -> FilePath -> System.Fuse.SyncType
                          -> m Errno
halfsSynchronizeDirectory (HS _log _fs _fpdhMap) _fp _syncType = do
  error "halfsSynchronizeDirectory: Not Yet Implemented." -- TODO
  return eNOSYS
         
halfsAccess :: HalfsCapable b t r l m =>
               HalfsSpecific b r l m
            -> FilePath -> Int
            -> m Errno
halfsAccess (HS log _fs _fpdhMap) fp n = do
  log $ "halfsAccess: fp = " ++ show fp ++ ", n = " ++ show n
  return eOK -- TODO FIXME currently grants all access!
         
halfsInit :: HalfsCapable b t r l m =>
             HalfsSpecific b r l m
          -> m ()
halfsInit (HS log _fs _fpdhMap) = do
  log $ "halfsInit: Invoked."
  return ()

halfsDestroy :: HalfsCapable b t r l m =>
                HalfsSpecific b r l m
             -> m ()
halfsDestroy (HS log fs _fpdhMap) = do
  log $ "halfsDestroy: Unmounting..." 
  exec $ unmount fs
  log "halfsDestroy: Shutting block device down..."        
  exec $ lift $ bdShutdown (hsBlockDev fs)
  log $ "halfsDestroy: Done."
  return ()

--------------------------------------------------------------------------------
-- Converters

hfstat2fstat :: (Show t, Timed t m) => H.FileStat t -> m FileStat 
hfstat2fstat stat = do
  atm  <- toCTime $ H.fsAccessTime stat
  mtm  <- toCTime $ H.fsModifyTime stat
  chtm <- toCTime $ H.fsChangeTime stat
  let entryType = case H.fsType stat of
                    H.RegularFile -> RegularFile
                    H.Directory   -> Directory
                    H.Symlink     -> SymbolicLink
                    -- TODO: Represent remaining FUSE entry types
                    H.AnyFileType -> error "Invalid fstat type"
  return FileStat
    { statEntryType        = entryType
    , statFileMode         = entryTypeToFileMode entryType
                             .|. emode (H.fsMode stat)
    , statLinkCount        = chkb16 $ H.fsNumLinks stat
    , statFileOwner        = chkb32 $ H.fsUID stat
    , statFileGroup        = chkb32 $ H.fsGID stat
    , statSpecialDeviceID  = 0 -- XXX/TODO: Do we need to distinguish by
                               -- blkdev, or is this for something else?
    , statFileSize         = fromIntegral $ H.fsSize stat
    , statBlocks           = fromIntegral $ H.fsNumBlocks stat
    , statAccessTime       = atm
    , statModificationTime = mtm
    , statStatusChangeTime = chtm
    }
  where
    chkb16 x = assert (x' <= fromIntegral (maxBound :: Word16)) x'
               where x' = fromIntegral x
    chkb32 x = assert (x' <= fromIntegral (maxBound :: Word32)) x'
               where x' = fromIntegral x
    emode (H.FileMode o g u) = cvt o * 0o100 + cvt g * 0o10 + cvt u where
      cvt = foldr (\p acc -> acc + case p of H.Read    -> 0o4
                                             H.Write   -> 0o2
                                             H.Execute -> 0o1
                  ) 0

-- NB: Something like this should probably be done by HFuse. TODO: Migrate?
mode2hmode :: FileMode -> H.FileMode
mode2hmode mode = H.FileMode (perms 6) (perms 3) (perms 0)
  where
    msk b   = case b of H.Read -> 4; H.Write -> 2; H.Execute -> 1
    perms k = chk H.Read ++ chk H.Write ++ chk H.Execute 
      where chk b = if mode .&. msk b `shiftL` k /= 0 then [b] else []

--------------------------------------------------------------------------------
-- Misc

exec :: Monad m => HalfsT m a -> m a
exec act =
  runHalfs act >>= \ea -> case ea of
    Left e  -> fail $ show e
    Right x -> return x

-- | Returns the result of the given action on success, otherwise yields an
-- Errno for the failed operation.  The Errno comes from either a HalfsM
-- exception signifying it holds an Errno, or the default provided as the first
-- argument.
execOrErrno :: Monad m => Errno -> (a -> b) -> HalfsT m a -> m (Either Errno b)
execOrErrno defaultEn f act = do
 runHalfs act >>= \ea -> case ea of
   Left (HE_ErrnoAnnotated _ en) -> return $ Left en
   Left _                        -> return $ Left defaultEn
   Right x                       -> return $ Right (f x)

execToErrno :: Monad m => Errno -> (a -> Errno) -> HalfsT m a -> m Errno
execToErrno defaultEn f = liftM (either id id) . execOrErrno defaultEn f

withLogger :: HalfsCapable b t r l m =>
              Logger m -> HalfsState b r l m -> HalfsState b r l m 
withLogger log fs = fs {hsLogger = Just log}

--------------------------------------------------------------------------------
-- Command line stuff

data Options = Options
  { optFileDev :: Maybe FilePath
  , optMemDev  :: Bool
  , optNumSecs :: Word64
  , optSecSize :: Word64
  , optLogFile :: FilePath
  }
  deriving (Show)

defOpts :: Options
defOpts = Options
  { optFileDev = Nothing
  , optMemDev  = True
  , optNumSecs = 512
  , optSecSize = 512
  , optLogFile = "halfs.log"
  } 

options :: [OptDescr (Options -> Options)]
options =
  [ Option ['m'] ["memdev"]
      (NoArg $ \opts -> opts{ optFileDev = Nothing, optMemDev = True })
      "use memory device"
  , Option ['f'] ["filedev"]
      (ReqArg (\f opts -> opts{ optFileDev = Just f, optMemDev = False })
              "PATH"
      )
      "use file-backed device"
  , Option ['n'] ["numsecs"]
      (ReqArg (\s0 opts -> let s1 = Prelude.read s0 in opts{ optNumSecs = s1 })
              "SIZE"
      )
      "number of sectors (ignored for filedevs; default 512)"
  , Option ['s'] ["secsize"]
      (ReqArg (\s0 opts -> let s1 = Prelude.read s0 in opts{ optSecSize = s1 })
              "SIZE"
      )
      "sector size in bytes (ignored for existing filedevs; default 512)"
  , Option ['l'] ["logfile"]
      (ReqArg (\s opts -> opts{ optLogFile = s })
              "PATH"
      )
      "filename for halfs logging (default ./halfs.log)"
  ]

--------------------------------------------------------------------------------
-- Instances for debugging

instance Show OpenMode where
  show ReadOnly  = "ReadOnly"
  show WriteOnly = "WriteOnly"
  show ReadWrite = "ReadWrite"

instance Show OpenFileFlags where
  show (OpenFileFlags append' exclusive' noctty' nonBlock' trunc') =
    "OpenFileFlags " ++
    "{ append = "    ++ show append'    ++
    ", exclusive = " ++ show exclusive' ++
    ", noctty = "    ++ show noctty'    ++
    ", nonBlock = "  ++ show nonBlock'  ++
    ", trunc = "     ++ show trunc'     ++
    "}"
