{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RecursiveDo #-}

module Plugin.SimulaServer where

import Control.Concurrent
import System.Posix.Process
import System.Process
import qualified System.Process.ByteString as B
import qualified Data.ByteString.Char8 as B
import System.Process.Internals
import System.Posix.Types
import System.Posix.Signals
import System.Directory
import           Data.Bits
import           Linear
import           Plugin.Imports

import Godot.Core.GodotVisualServer          as G
import qualified Godot.Gdnative.Internal.Api as Api
import qualified Godot.Methods               as G
import           Godot.Nativescript

import qualified Data.Map.Strict as M

import Data.UUID
import Data.UUID.V1

import Plugin.Input
import Plugin.SimulaViewSprite
import Plugin.Types

import Control.Monad
import Control.Concurrent
import System.Environment

import System.Process

import Telemetry

import           Debug.Trace
import           Control.Lens hiding (Context)
import           Control.Concurrent.STM.TVar
import           Control.Exception
import           Control.Monad
import           Control.Monad.STM
import           Data.Maybe
import           Data.List
import           Data.Coerce
import           Unsafe.Coerce
import           Data.Either

import           Foreign hiding (void)
import           Foreign.C.Error
import           Foreign.Ptr
import           Foreign.Marshal.Alloc
import           Foreign.C.Types
import qualified Language.C.Inline as C

import           Plugin.CanvasBase
import           Plugin.CanvasSurface

import           System.Clock
import           Control.Monad.Extra

import Godot.Core.GodotGlobalConstants as G
import Godot.Core.GodotInput as G

instance NativeScript GodotSimulaServer where
  -- className = "SimulaServer"
  classInit spatial = initGodotSimulaServer (safeCast spatial)

  -- classExtends = "Spatial"
  classMethods =
    [ func NoRPC "_ready" Plugin.SimulaServer.ready
    , func NoRPC "_input" Plugin.SimulaServer._input
    -- , func NoRPC "_input" Plugin.SimulaServer.input -- replaced by _on_wlr_* handlers
    , func NoRPC "_on_WaylandDisplay_ready"    Plugin.SimulaServer._on_WaylandDisplay_ready
    , func NoRPC "_on_WlrXdgShell_new_surface" Plugin.SimulaServer._on_WlrXdgShell_new_surface
    , func NoRPC "handle_map_surface" Plugin.SimulaServer.handle_map_surface
    , func NoRPC "handle_unmap_surface" Plugin.SimulaServer.handle_unmap_surface
    , func NoRPC "_on_wlr_key" Plugin.SimulaServer._on_wlr_key
    , func NoRPC "_on_wlr_modifiers" Plugin.SimulaServer._on_wlr_modifiers
    , func NoRPC "_on_WlrXWayland_new_surface" Plugin.SimulaServer._on_WlrXWayland_new_surface
    , func NoRPC "_physics_process" Plugin.SimulaServer.physicsProcess
    , func NoRPC "_on_simula_shortcut" Plugin.SimulaServer._on_simula_shortcut
    ]

  classSignals = []

ready :: GodotSimulaServer -> [GodotVariant] -> IO ()
ready gss _ = do
  -- Delete log file
  readProcess "touch" ["./log.txt"] []
  readProcess "rm" ["./log.txt"] []

  -- putStrLn "ready in SimulaServer.hs"
  -- Set state / start compositor
  addWlrChildren gss

  -- Get state
  wlrSeat <- readTVarIO (gss ^. gssWlrSeat)
  wlrKeyboard <- readTVarIO (gss ^. gssWlrKeyboard)

  -- Set state
  G.set_keyboard wlrSeat (safeCast wlrKeyboard)

  -- Connect signals
  connectGodotSignal wlrKeyboard "key" gss "_on_wlr_key" []
  connectGodotSignal wlrKeyboard "modifiers" gss "_on_wlr_modifiers" []
  connectGodotSignal wlrKeyboard "shortcut" gss "_on_simula_shortcut" []
    -- Omission: We omit connecting "size_changed" with "_on_viewport_change"

  -- wlrSeat <- readTVarIO (gss ^. gssWlrSeat)
  wlrCompositor <- readTVarIO (gss ^. gssWlrCompositor)
  wlrXWayland <- readTVarIO (gss ^. gssWlrXWayland)


  oldDisplay <- getEnv "DISPLAY"

  -- We wait till here to start XWayland so we can feed it a seat + compositor
  G.start_xwayland wlrXWayland (safeCast wlrCompositor) (safeCast wlrSeat)

  newDisplay <- getEnv "DISPLAY"
  putStr "New DISPLAY="
  putStrLn newDisplay
  setEnv "DISPLAY" oldDisplay
  if (newDisplay /= oldDisplay)
    then atomically $ writeTVar (gss ^. gssXWaylandDisplay) (Just newDisplay)
    else atomically $ writeTVar (gss ^. gssXWaylandDisplay) Nothing

  connectGodotSignal wlrXWayland "new_surface" gss "_on_WlrXWayland_new_surface" []

  startTelemetry (gss ^. gssViews)

  viewport <- G.get_viewport gss :: IO GodotViewport
  connectGodotSignal viewport "input_event" gss "_mouse_input" []

  getSingleton GodotInput "Input" >>= \inp -> G.set_mouse_mode inp G.MOUSE_MODE_CAPTURED
  pid <- getProcessID

  createProcess (shell "./result/bin/xrdb -merge .Xdefaults") { env = Just [("DISPLAY", newDisplay)] }

  (_, windows', _) <- B.readCreateProcessWithExitCode (shell "./result/bin/wmctrl -lp") ""
  let windows = (B.unpack windows')
  let rightWindows = filter (\line -> isInfixOf (show pid) line) (lines windows)
  let simulaWindow = (head . words . head) rightWindows
  createProcess ((shell $ "./result/bin/wmctrl -ia " ++ simulaWindow) { env = Just [("DISPLAY", oldDisplay)] })

  appendFile "log.txt" "Starting logs..\n"
  terminalLaunch gss
  -- launchXpra gss

-- | Populate the GodotSimulaServer's TVar's with Wlr types; connect some Wlr methods
-- | to their signals. This implicitly starts the compositor.
addWlrChildren :: GodotSimulaServer -> IO ()
addWlrChildren gss = do
  -- putStrLn "addWlrChildren"
  -- Here we assume gss is already a node in our scene tree.

  -- WaylandDisplay
  waylandDisplay <- unsafeInstance GodotWaylandDisplay "WaylandDisplay"
  setWaylandSocket waylandDisplay "simula-0"
  atomically $ writeTVar (_gssWaylandDisplay gss) waylandDisplay
  connectGodotSignal waylandDisplay "ready" gss "_on_WaylandDisplay_ready" [] -- [connection signal="ready" from="WaylandDisplay" to="." method="_on_WaylandDisplay_ready"]
  G.set_name waylandDisplay =<< toLowLevel "WaylandDisplay"
  G.add_child gss ((safeCast waylandDisplay) :: GodotNode) True -- Triggers "ready" signal, calls "_on_WaylandDisplay_ready", and starts the compositor

  -- We omit having ViewportBounds children

  -- Children of WaylandDisplay
  wlrDataDeviceManager <- unsafeInstance GodotWlrDataDeviceManager "WlrDataDeviceManager"
  atomically $ writeTVar (_gssWlrDataDeviceManager gss) wlrDataDeviceManager
  G.set_name wlrDataDeviceManager =<< toLowLevel "WlrDataDeviceManager"
  G.add_child ((safeCast waylandDisplay) :: GodotNode) ((safeCast wlrDataDeviceManager) :: GodotNode) True

  wlrBackend <- unsafeInstance GodotWlrBackend "WlrBackend"
  atomically $ writeTVar (_gssWlrBackend gss) wlrBackend
  G.set_name wlrBackend =<< toLowLevel "WlrBackend"
  G.add_child waylandDisplay ((safeCast wlrBackend) :: GodotNode) True

  wlrXdgShell <- unsafeInstance GodotWlrXdgShell "WlrXdgShell"
  connectGodotSignal wlrXdgShell "new_surface" gss "_on_WlrXdgShell_new_surface" [] -- [connection signal="new_surface" from="WaylandDisplay/WlrXdgShell" to="." method="_on_WlrXdgShell_new_surface"]
  atomically $ writeTVar (_gssWlrXdgShell gss) wlrXdgShell
  G.set_name wlrXdgShell =<< toLowLevel "WlrXdgShell"
  G.add_child waylandDisplay ((safeCast wlrXdgShell) :: GodotNode) True

  wlrXWayland <- unsafeInstance GodotWlrXWayland "WlrXWayland"
  -- Don't start XWayland until `ready`
  -- connectGodotSignal wlrXWayland "new_surface" gss "_on_WlrXWayland_new_surface" [] -- [connection signal="new_surface" from="WaylandDisplay/WlrXWayland" to="." method="_on_WlrXWayland_new_surface"]
  atomically $ writeTVar (_gssWlrXWayland gss) wlrXWayland
  G.set_name wlrXWayland =<< toLowLevel "WlrXWayland"
  G.add_child waylandDisplay ((safeCast wlrXWayland) :: GodotNode) True

  wlrSeat <- unsafeInstance GodotWlrSeat "WlrSeat"
  G.set_capabilities wlrSeat 3
  atomically $ writeTVar (_gssWlrSeat gss) wlrSeat
  G.set_name wlrSeat =<< toLowLevel "WlrSeat"
  G.add_child waylandDisplay ((safeCast wlrSeat) :: GodotNode) True

  wlrKeyboard <- unsafeInstance GodotWlrKeyboard "WlrKeyboard"
  atomically $ writeTVar (_gssWlrKeyboard gss) wlrKeyboard
  G.set_name wlrKeyboard =<< toLowLevel "WlrKeyboard"
  G.add_child waylandDisplay ((safeCast wlrKeyboard) :: GodotNode) True

  -- Children of WlrBackend
  wlrOutput <- unsafeInstance GodotWlrOutput "WlrOutput"
  atomically $ writeTVar (_gssWlrOutput gss) wlrOutput
  G.set_name wlrOutput =<< toLowLevel "WlrOutput"
  G.add_child wlrBackend ((safeCast wlrOutput) :: GodotNode) True

  wlrCompositor <- unsafeInstance GodotWlrCompositor "WlrCompositor"
  atomically $ writeTVar (_gssWlrCompositor gss) wlrCompositor
  G.set_name wlrCompositor =<< toLowLevel "WlrCompositor"
  G.add_child wlrBackend ((safeCast wlrCompositor) :: GodotNode) True

  rc <- readTVarIO (gss ^. gssHMDRayCast)
  addChild gss rc

  return ()
  where setWaylandSocket :: GodotWaylandDisplay -> String -> IO ()
        setWaylandSocket waylandDisplay socketName = do
          socketName' <- toLowLevel (pack socketName)
          G.set_socket_name waylandDisplay socketName'

-- | We first fill the TVars with dummy state, before updating them with their
-- | real values in `ready`.
initGodotSimulaServer :: GodotObject -> IO (GodotSimulaServer)
initGodotSimulaServer obj = do
  -- putStrLn "initGodotSimulaServer"
  gssWaylandDisplay'       <- newTVarIO (error "Failed to initialize GodotSimulaServer") :: IO (TVar GodotWaylandDisplay)
  gssWlrBackend'           <- newTVarIO (error "Failed to initialize GodotSimulaServer") :: IO (TVar GodotWlrBackend)
  gssWlrOutput'            <- newTVarIO (error "Failed to initialize GodotSimulaServer") :: IO (TVar GodotWlrOutput)
  gssWlrCompositor'        <- newTVarIO (error "Failed to initialize GodotSimulaServer") :: IO (TVar GodotWlrCompositor)
  gssWlrXdgShell'          <- newTVarIO (error "Failed to initialize GodotSimulaServer") :: IO (TVar GodotWlrXdgShell)
  gssWlrSeat'              <- newTVarIO (error "Failed to initialize GodotSimulaServer") :: IO (TVar GodotWlrSeat)
  gssWlrXWayland'          <- newTVarIO (error "Failed to initialize GodotSimulaServer") :: IO (TVar GodotWlrXWayland)
  gssWlrDataDeviceManager' <- newTVarIO (error "Failed to initialize GodotSimulaServer") :: IO (TVar GodotWlrDataDeviceManager)
  gssWlrKeyboard'          <- newTVarIO (error "Failed to initialize GodotSimulaServer") :: IO (TVar GodotWlrKeyboard)
  gssViews'                <- newTVarIO M.empty                                          :: IO (TVar (M.Map SimulaView GodotSimulaViewSprite))
  gssKeyboardFocusedSprite' <- newTVarIO Nothing :: IO (TVar (Maybe GodotSimulaViewSprite))
  visualServer <- getSingleton GodotVisualServer "VisualServer"
  visualServer' <- newTVarIO visualServer
  gssActiveCursorGSVS' <- newTVarIO Nothing

  maybeCursorTexture <- getTextureFromURL "res://cursor.png"
  gssCursorTexture' <- newTVarIO maybeCursorTexture

  rc <- unsafeInstance GodotRayCast "RayCast"
  G.set_cast_to rc =<< toLowLevel (V3 0 0 (negate 10))
  G.set_enabled rc True
  gssHMDRayCast' <- newTVarIO rc

  gssKeyboardGrabbedSprite' <- newTVarIO Nothing
  gssXWaylandDisplay'       <- newTVarIO Nothing

  gssOriginalEnv' <- getEnvironment

  gssFreeChildren' <- newTVarIO M.empty :: IO (TVar (M.Map GodotWlrXWaylandSurface CanvasSurface))

  let gss = GodotSimulaServer {
    _gssObj                   = obj                       :: GodotObject
  , _gssWaylandDisplay        = gssWaylandDisplay'        :: TVar GodotWaylandDisplay
  , _gssWlrBackend            = gssWlrBackend'            :: TVar GodotWlrBackend
  , _gssWlrOutput             = gssWlrOutput'             :: TVar GodotWlrOutput
  , _gssWlrCompositor         = gssWlrCompositor'         :: TVar GodotWlrCompositor
  , _gssWlrXdgShell           = gssWlrXdgShell'           :: TVar GodotWlrXdgShell
  , _gssWlrXWayland           = gssWlrXWayland'           :: TVar GodotWlrXWayland
  , _gssWlrSeat               = gssWlrSeat'               :: TVar GodotWlrSeat
  , _gssWlrDataDeviceManager  = gssWlrDataDeviceManager'  :: TVar GodotWlrDataDeviceManager
  , _gssWlrKeyboard           = gssWlrKeyboard'           :: TVar GodotWlrKeyboard
  , _gssViews                 = gssViews'                 :: TVar (M.Map SimulaView GodotSimulaViewSprite)
  , _gssKeyboardFocusedSprite = gssKeyboardFocusedSprite' :: TVar (Maybe GodotSimulaViewSprite)
  , _gssVisualServer          = visualServer'             :: TVar GodotVisualServer
  , _gssActiveCursorGSVS      = gssActiveCursorGSVS'      :: TVar (Maybe GodotSimulaViewSprite)
  , _gssCursorTexture         = gssCursorTexture'         :: TVar (Maybe GodotTexture)
  , _gssHMDRayCast            = gssHMDRayCast'            :: TVar GodotRayCast
  , _gssKeyboardGrabbedSprite = gssKeyboardGrabbedSprite' :: TVar (Maybe (GodotSimulaViewSprite, Float))
  , _gssXWaylandDisplay       = gssXWaylandDisplay'       :: TVar (Maybe String)
  , _gssOriginalEnv           = gssOriginalEnv'           :: [(String, String)]
  , _gssFreeChildren          = gssFreeChildren'          :: TVar (M.Map GodotWlrXWaylandSurface CanvasSurface)
  }

  return gss
  where getTextureFromURL :: String -> IO (Maybe GodotTexture)
        getTextureFromURL urlStr = do
          godotImage <- unsafeInstance GodotImage "Image" :: IO GodotImage
          godotImageTexture <- unsafeInstance GodotImageTexture "ImageTexture"
          pngUrl <- toLowLevel (pack urlStr) :: IO GodotString
          exitCode <- G.load godotImage pngUrl
          G.create_from_image godotImageTexture godotImage G.TEXTURE_FLAGS_DEFAULT
          if (unsafeCoerce godotImageTexture == nullPtr) then (return Nothing) else (return (Just (safeCast godotImageTexture)))

-- Don't think we should need this. Delete after a while.
-- getSimulaServerNodeFromPath :: GodotSimulaServer -> String -> IO a
-- getSimulaServerNodeFromPath gss nodePathStr = do
--   nodePath <- (toLowLevel (pack nodePathStr))
--   gssNode <- G.get_node ((safeCast gss) :: GodotNode) nodePath
--   ret  <- (fromNativeScript (safeCast gssNode)) :: IO a
--   return ret

_on_WaylandDisplay_ready :: GodotSimulaServer -> [GodotVariant] -> IO ()
_on_WaylandDisplay_ready gss _ = do
  -- putStrLn "_on_WaylandDisplay_ready"
  --waylandDisplay <- getSimulaServerNodeFromPath gss "WaylandDisplay"
  waylandDisplay <- atomically $ readTVar (_gssWaylandDisplay gss)
  G.run waylandDisplay
  return ()

_on_WlrXdgShell_new_surface :: GodotSimulaServer -> [GodotVariant] -> IO ()
_on_WlrXdgShell_new_surface gss [wlrXdgSurfaceVariant] = do
  wlrXdgSurface <- fromGodotVariant wlrXdgSurfaceVariant :: IO GodotWlrXdgSurface -- Not sure if godot-haskell provides this for us
  roleInt <- G.get_role wlrXdgSurface
  case roleInt of
      0 -> return () -- XDG_SURFACE_ROLE_NONE
      2 -> return () -- XDG_SURFACE_ROLE_POPUP
      1 -> do                    -- XDG_SURFACE_ROLE_TOPLEVEL
              simulaView <- newSimulaView gss wlrXdgSurface
              gsvs <- newGodotSimulaViewSprite gss simulaView

              -- Mutate the server with our updated state
              atomically $ modifyTVar' (_gssViews gss) (M.insert simulaView gsvs) -- TVar (M.Map SimulaView GodotSimulaViewSprite)

              --surface.connect("map", self, "handle_map_surface")
              connectGodotSignal gsvs "map" gss "handle_map_surface" []
              --surface.connect("unmap", self, "handle_unmap_surface")
              connectGodotSignal gsvs "unmap" gss "handle_unmap_surface" []

              -- _xdg_surface_set logic from godotston:
              -- xdg_surface.connect("destroy", self, "_handle_destroy"):
              connectGodotSignal wlrXdgSurface "destroy" gsvs "_handle_destroy" []
              -- xdg_surface.connect("map", self, "_handle_map"):
              connectGodotSignal wlrXdgSurface "map" gsvs "_handle_map" []
              -- xdg_surface.connect("unmap", self, "_handle_unmap"):
              connectGodotSignal wlrXdgSurface "unmap" gsvs "_handle_unmap" []

              -- Add the gsvs as a child to the SimulaServer
              G.add_child ((safeCast gss) :: GodotNode )
                          ((safeCast gsvs) :: GodotNode)
                          True

              -- Handles 2D window movement across a viewport; not needed:
              -- toplevel.connect("request_move", self, "_handle_request_move")
              return ()


   where newSimulaView :: GodotSimulaServer -> GodotWlrXdgSurface -> IO (SimulaView)
         newSimulaView gss wlrXdgSurface = do
          let gss' = gss :: GodotSimulaServer
          svMapped' <- atomically (newTVar False) :: IO (TVar Bool)
          let gsvsWlrXdgSurface' = wlrXdgSurface
          gsvsUUID' <- nextUUID :: IO (Maybe UUID)

          return SimulaView
              { _svServer           = gss :: GodotSimulaServer
              , _svMapped           = svMapped' :: TVar Bool
              , _svWlrEitherSurface = (Left wlrXdgSurface) :: Either GodotWlrXdgSurface GodotWlrXWaylandSurface
              , _gsvsUUID           = gsvsUUID' :: Maybe UUID
              }

handle_map_surface :: GodotSimulaServer -> [GodotVariant] -> IO ()
handle_map_surface gss [gsvsVariant] = do
  maybeGsvs <- variantToReg gsvsVariant :: IO (Maybe GodotSimulaViewSprite)
  case maybeGsvs of
    Nothing -> putStrLn "Failed to cast GodotSimulaViewSprite in handle_map_surface!"
    Just gsvs -> do -- Delay adding the sprite to the scene graph until we know XCB intends for it to be mapped
                    putStr "Mapping surface "
                    print (safeCast @GodotObject gsvs)
                    G.add_child ((safeCast gss) :: GodotNode )
                                ((safeCast gsvs) :: GodotNode)
                                True

                    cb <- newCanvasBase gsvs
                    viewportBase <- readTVarIO (cb ^. cbViewport)

                    atomically $ writeTVar (gsvs ^. gsvsCanvasBase) cb
                    G.set_process cb True
                    addChild gsvs viewportBase
                    addChild viewportBase cb

                    setInFrontOfUser gsvs (-2)

                    V3 1 1 1 ^* (1 + 1 * 1) & toLowLevel >>= G.scale_object_local (safeCast gsvs :: GodotSpatial)

                    focus gsvs -- We're relying on this to add references to wlrSurface :/

                    simulaView <- atomically $ readTVar (gsvs ^. gsvsView)
                    atomically $ writeTVar (simulaView ^. svMapped) True
  return ()

handle_unmap_surface :: GodotSimulaServer -> [GodotVariant] -> IO ()
handle_unmap_surface gss [gsvsVariant] = do
  maybeGsvs <- variantToReg gsvsVariant :: IO (Maybe GodotSimulaViewSprite)
  case maybeGsvs of
    Nothing -> putStrLn "Failed to cast GodotSimulaViewSprite!"
    Just gsvs -> do simulaView <- atomically $ readTVar (gsvs ^. gsvsView)
                    atomically $ writeTVar (simulaView ^. svMapped) False
                    removeChild gss gsvs
                    -- Deletion should be handled elsewhere.
  return ()

_on_wlr_key :: GodotSimulaServer -> [GodotVariant] -> IO ()
_on_wlr_key gss [keyboardGVar, eventGVar] = do
  wlrSeat <- readTVarIO (gss ^. gssWlrSeat)
  event <- fromGodotVariant eventGVar
  G.reference event
  G.keyboard_notify_key wlrSeat event
  return ()

_on_wlr_modifiers :: GodotSimulaServer -> [GodotVariant] -> IO ()
_on_wlr_modifiers gss [keyboardGVar] = do
  wlrSeat <- readTVarIO (gss ^. gssWlrSeat)
  G.keyboard_notify_modifiers wlrSeat
  return ()

_on_WlrXWayland_new_surface :: GodotSimulaServer -> [GodotVariant] -> IO ()
_on_WlrXWayland_new_surface gss [wlrXWaylandSurfaceVariant] = do
  wlrXWaylandSurface <- fromGodotVariant wlrXWaylandSurfaceVariant :: IO GodotWlrXWaylandSurface
  G.reference wlrXWaylandSurface
  simulaView <- newSimulaView gss wlrXWaylandSurface
  gsvs <- newGodotSimulaViewSprite gss simulaView

  atomically $ modifyTVar' (_gssViews gss) (M.insert simulaView gsvs) -- TVar (M.Map SimulaView GodotSimulaViewSprite)

  connectGodotSignal gsvs "map" gss "handle_map_surface" []
  connectGodotSignal gsvs "unmap" gss "handle_unmap_surface" []
  connectGodotSignal wlrXWaylandSurface "map_free_child" gsvs "handle_map_free_child" []
  connectGodotSignal wlrXWaylandSurface "destroy" gsvs "_handle_destroy" []
  connectGodotSignal wlrXWaylandSurface "map" gsvs "_handle_map" []
  connectGodotSignal wlrXWaylandSurface "unmap" gsvs "_handle_unmap" []
  return ()
  where newSimulaView :: GodotSimulaServer -> GodotWlrXWaylandSurface -> IO (SimulaView)
        newSimulaView gss wlrXWaylandSurface = do
         let gss' = gss :: GodotSimulaServer
         svMapped' <- atomically (newTVar False) :: IO (TVar Bool)
         -- let gsvsWlrXWaylandSurface' = wlrXWaylandSurface
         gsvsUUID' <- nextUUID :: IO (Maybe UUID)

         return SimulaView
             { _svServer           = gss :: GodotSimulaServer
             , _svMapped           = svMapped' :: TVar Bool
             , _svWlrEitherSurface = (Right wlrXWaylandSurface) :: Either GodotWlrXdgSurface GodotWlrXWaylandSurface
             , _gsvsUUID           = gsvsUUID' :: Maybe UUID
             }

-- Find the cursor-active gsvs, convert relative godot mouse movement to new
-- mouse coordinates, and pass off to processClickEvent or pointer_notify_axis
_input :: GodotSimulaServer -> [GodotVariant] -> IO ()
_input gss [eventGV] = do
  event <- fromGodotVariant eventGV :: IO GodotInputEventMouseMotion
  maybeActiveGSVS <- readTVarIO (gss ^. gssActiveCursorGSVS)

  whenM (event `isClass` "InputEventMouseMotion") $ do
     mouseRelativeGV2 <- G.get_relative event :: IO GodotVector2
     mouseRelative@(V2 dx dy) <- fromLowLevel mouseRelativeGV2
     case maybeActiveGSVS of
         Nothing -> putStrLn "movement: No cursor focused surface!"
         (Just gsvs) -> do updateCursorStateRelative gsvs dx dy
                           sendWlrootsMotion gsvs
  whenM (event `isClass` "InputEventMouseButton") $ do
    let event' = GodotInputEventMouseButton (coerce event)
    pressed <- G.is_pressed event'
    button <- G.get_button_index event'
    wlrSeat <- readTVarIO (gss ^. gssWlrSeat)
    case (maybeActiveGSVS, button) of
         (Just gsvs, G.BUTTON_WHEEL_UP) -> G.pointer_notify_axis_continuous wlrSeat 0 (0.05)
         (Just gsvs, G.BUTTON_WHEEL_DOWN) -> G.pointer_notify_axis_continuous wlrSeat 0 (-0.05)
         (Just gsvs, _) -> do activeGSVSCursorPos@(SurfaceLocalCoordinates (sx, sy)) <- readTVarIO (gsvs ^. gsvsCursorCoordinates)
                              processClickEvent' gsvs (Button pressed button) activeGSVSCursorPos
         (Nothing, _) -> putStrLn "Button: No cursor focused surface!"

updateCursorStateRelative :: GodotSimulaViewSprite -> Float -> Float -> IO ()
updateCursorStateRelative gsvs dx dy = do
    activeGSVSCursorPos@(SurfaceLocalCoordinates (sx, sy)) <- readTVarIO (gsvs ^. gsvsCursorCoordinates)
    cb <- readTVarIO (gsvs ^. gsvsCanvasBase)
    textureViewport <- readTVarIO (cb ^. cbViewport)
    tvGV2 <- G.get_size textureViewport
    (V2 mx my) <- fromLowLevel tvGV2

    let sx' = if ((sx + dx) < mx) then (sx + dx) else mx
    let sx'' = if (sx' > 0) then sx' else 0
    let sy' = if ((sy + dy) < my) then (sy + dy) else my
    let sy'' = if (sy' > 0) then sy' else 0
    atomically $ writeTVar (gsvs ^. gsvsCursorCoordinates) (SurfaceLocalCoordinates (sx'', sy''))

updateCursorStateAbsolute :: GodotSimulaViewSprite -> Float -> Float -> IO ()
updateCursorStateAbsolute gsvs sx sy = do
    cb <- readTVarIO (gsvs ^. gsvsCanvasBase)
    textureViewport <- readTVarIO (cb ^. cbViewport)
    tvGV2 <- G.get_size textureViewport
    (V2 mx my) <- fromLowLevel tvGV2

    let sx' = if (sx < mx) then sx else mx
    let sx'' = if (sx' > 0) then sx' else 0
    let sy' = if (sy < my) then sy else my
    let sy'' = if (sy' > 0) then sy' else 0
    atomically $ writeTVar (gsvs ^. gsvsCursorCoordinates) (SurfaceLocalCoordinates (sx'', sy''))

sendWlrootsMotion :: GodotSimulaViewSprite -> IO ()
sendWlrootsMotion gsvs = do
    activeGSVSCursorPos@(SurfaceLocalCoordinates (sx, sy)) <- readTVarIO (gsvs ^. gsvsCursorCoordinates)
    processClickEvent' gsvs Motion activeGSVSCursorPos

getHMDLookAtSprite :: GodotSimulaServer -> IO (Maybe (GodotSimulaViewSprite, SurfaceLocalCoordinates))
getHMDLookAtSprite gss = do
  rc <- readTVarIO (gss ^.  gssHMDRayCast)
  hmdGlobalTransform <- getARVRCameraOrPancakeCameraTransform gss
  G.set_global_transform rc hmdGlobalTransform

  isColliding <- G.is_colliding rc
  maybeSprite <- if isColliding then G.get_collider rc >>= asNativeScript :: IO (Maybe GodotSimulaViewSprite) else (return Nothing)
  ret <- case maybeSprite of
            Nothing -> return Nothing
            Just gsvs -> do gv3 <- G.get_collision_point rc :: IO GodotVector3
                            surfaceLocalCoords@(SurfaceLocalCoordinates (sx, sy)) <- getSurfaceLocalCoordinates gsvs gv3
                            return $ Just (gsvs, surfaceLocalCoords)
  return ret

physicsProcess :: GodotSimulaServer -> [GodotVariant] -> IO ()
physicsProcess gss _ = do
  arvrCameraTransform <- getARVRCameraOrPancakeCameraTransform gss

  maybeKeyboardGrabbedGSVS <- readTVarIO (gss ^. gssKeyboardGrabbedSprite)
  maybeLookAtGSVS <- getHMDLookAtSprite gss

  case (maybeKeyboardGrabbedGSVS, maybeLookAtGSVS) of
    (Just (gsvs, dist), _) -> do setInFrontOfUser gsvs dist
                                 orientSpriteTowardsGaze gsvs
    (Nothing, Just (gsvs, surfaceLocalCoords@(SurfaceLocalCoordinates (sx, sy)))) -> do -- putStrLn $ "Looking at sprite: " ++ (show sx) ++ ", " ++ (show sy)
                                                                                        -- orientSpriteTowardsGaze gsvs
                                                                                        focus gsvs
    _ -> return ()

  return ()

-- Run shell command with DISPLAY set to its original (typically :1).
shellCmd1 :: GodotSimulaServer -> String -> IO ()
shellCmd1 gss appStr = do
  let originalEnv = (gss ^. gssOriginalEnv)
  createProcess (shell appStr) { env = Just originalEnv }
  return ()

-- Run shell command with DISPLAY set to our XWayland server value (typically
-- :2)
appLaunch :: GodotSimulaServer -> String -> [String] -> IO ()
appLaunch gss appStr args = do
  -- We shouldn't need to set WAYLAND_DISPLAY, but do need to set Xwayland DISPLAY
  let originalEnv = (gss ^. gssOriginalEnv)
  maybeXwaylandDisplay <- readTVarIO (gss ^. gssXWaylandDisplay)
  case maybeXwaylandDisplay of
    Nothing -> putStrLn "No DISPLAY found!"
    (Just xwaylandDisplay) -> do
      let envMap = M.fromList originalEnv
      let envMapWithDisplay = M.insert "DISPLAY" xwaylandDisplay envMap
      -- let envMapWithDisplay = M.insert "DISPLAY" ":13" envMap
      let envListWithDisplay = M.toList envMapWithDisplay
      createProcess (proc appStr args) { env = Just envListWithDisplay, new_session = True, std_out = NoStream, std_err = NoStream }
      return ()
  return ()

terminalLaunch :: GodotSimulaServer -> IO ()
terminalLaunch gss = appLaunch gss "./result/bin/xfce4-terminal" []

-- Master routing function for keyboard-mouse-window manipulation. Guaranteed to
-- only be called if Simula's MOD key is pressed (currently set to `SUPER_L` or
-- `SUPER_R`) TODO: Feed this through a Simula config file to allow user shortcut
-- customization.
_on_simula_shortcut :: GodotSimulaServer -> [GodotVariant] -> IO ()
_on_simula_shortcut gss [godotScanCodeGVar, isPressedGVar] = do
  maybeHMDLookAtSprite <- getHMDLookAtSprite gss

  godotScanCode <- fromGodotVariant godotScanCodeGVar :: IO Int -- FULL scancode, including SUPER keys
  isPressed <- fromGodotVariant isPressedGVar :: IO Bool
  let keycode = godotScanCode .&. G.KEY_CODE_MASK

  case (maybeHMDLookAtSprite, keycode, isPressed) of
      (Just (gsvs, coords@(SurfaceLocalCoordinates (sx, sy))), G.KEY_APOSTROPHE, True) -> do
        updateCursorStateAbsolute gsvs sx sy
        sendWlrootsMotion gsvs
      (Just (gsvs, coords@(SurfaceLocalCoordinates (sx, sy))), G.KEY_SEMICOLON, True) -> do
        updateCursorStateAbsolute gsvs sx sy
        sendWlrootsMotion gsvs
      (Just (gsvs, coords@(SurfaceLocalCoordinates (sx, sy))), G.KEY_ENTER, True) -> do
        updateCursorStateAbsolute gsvs sx sy
        sendWlrootsMotion gsvs
        processClickEvent' gsvs (Button True 1) coords -- BUTTON_LEFT = 1
      (Just (gsvs, coords@(SurfaceLocalCoordinates (sx, sy))), G.KEY_ENTER, False) -> do
        processClickEvent' gsvs (Button False 1) coords -- BUTTON_LEFT = 1
      (_, G.KEY_SUPER_L, True) -> do
        terminalLaunch gss
      (_, G.KEY_SUPER_R, True) -> do
        terminalLaunch gss
      (_, G.KEY_X, True) -> do
        launchXpra gss
      (_, G.KEY_SLASH, True) -> do
        terminalLaunch gss
      (_, G.KEY_K, True) -> do
        appLaunch gss "firefox" ["-new-window"]
      (_, G.KEY_G, True) -> do
        appLaunch gss "google-chrome-stable" ["--new-window google.com"]
      (_, G.KEY_ESCAPE, True) -> do
        toggleGrabMode
      (_, G.KEY_W, True) -> do
        launchHMDWebCam gss
        -- appLaunch gss "ffplay" ["/dev/video2"]
        -- appLaunch gss "cheese" ["--fullscreen", "-d", "HTC Vive"]
      (Just (gsvs, coords@(SurfaceLocalCoordinates (sx, sy))), G.KEY_F, True) -> do
        orientSpriteTowardsGaze gsvs
      (Just (gsvs, coords@(SurfaceLocalCoordinates (sx, sy))), G.KEY_ALT, True) -> do
        keyboardGrabInitiate gsvs
      (Just (gsvs, coords@(SurfaceLocalCoordinates (sx, sy))), G.KEY_ALT, False) -> do
        keyboardGrabLetGo gsvs
      -- (Just (gsvs, coords@(SurfaceLocalCoordinates (sx, sy))), G.KEY_0, True) -> do
      --   orientSpriteTowardsGaze gsvs
      (Just (gsvs, coords@(SurfaceLocalCoordinates (sx, sy))), G.KEY_BRACKETLEFT, True) -> do
        moveSpriteAlongObjectZAxis gsvs (-0.1)
      (Just (gsvs, coords@(SurfaceLocalCoordinates (sx, sy))), G.KEY_BRACKETRIGHT, True) -> do
        moveSpriteAlongObjectZAxis gsvs 0.1
      (Just (gsvs, coords@(SurfaceLocalCoordinates (sx, sy))), G.KEY_9, True) -> do
        V3 1 1 1 ^* (1 + 1 * (-0.1)) & toLowLevel >>= G.scale_object_local (safeCast gsvs :: GodotSpatial)
      (Just (gsvs, coords@(SurfaceLocalCoordinates (sx, sy))), G.KEY_0, True) -> do
        V3 1 1 1 ^* (1 + 1 * 0.1) & toLowLevel >>= G.scale_object_local (safeCast gsvs :: GodotSpatial)
      (Just (gsvs, coords@(SurfaceLocalCoordinates (sx, sy))), G.KEY_EQUAL, True) -> do
        resizeGSVS gsvs (-50)
      (Just (gsvs, coords@(SurfaceLocalCoordinates (sx, sy))), G.KEY_MINUS, True) -> do
        resizeGSVS gsvs 50
      (Just (gsvs, coords@(SurfaceLocalCoordinates (sx, sy))), G.KEY_COMMA, True) -> do
        moveSpriteAlongObjectZAxis gsvs (-0.1)
      (Just (gsvs, coords@(SurfaceLocalCoordinates (sx, sy))), G.KEY_PERIOD, True) -> do
        moveSpriteAlongObjectZAxis gsvs 0.1
      (Just (gsvs, coords@(SurfaceLocalCoordinates (sx, sy))), G.KEY_BACKSPACE, True) -> do
        simulaView <- readTVarIO (gsvs ^. gsvsView)
        let eitherSurface = (simulaView ^. svWlrEitherSurface)
        case eitherSurface of
          (Left wlrXdgSurface) -> return ()
          (Right wlrXWaylandSurface) -> G.send_close wlrXWaylandSurface
      (Just (gsvs, coords@(SurfaceLocalCoordinates (sx, sy))), _, False) -> do
        keyboardGrabLetGo gsvs
      _ -> do
        putStrLn "Unrecognized shortcut!"

launchXpra :: GodotSimulaServer -> IO ()
launchXpra gss = do
  let originalEnv = (gss ^. gssOriginalEnv)
  maybeXwaylandDisplay <- readTVarIO (gss ^. gssXWaylandDisplay)
  case maybeXwaylandDisplay of
    Nothing -> putStrLn "No DISPLAY found!"
    (Just xwaylandDisplay) -> do
      let envMap = M.fromList originalEnv
      let envMapWithDisplay = M.insert "DISPLAY" xwaylandDisplay envMap
      let envListWithDisplay = M.toList envMapWithDisplay

      (_,output',_) <- B.readCreateProcessWithExitCode (shell "./result/bin/xpra list") ""
      let output = B.unpack output'
      let isXpraAlreadyLive = isInfixOf ":13" output
      case isXpraAlreadyLive of
        False -> do createSessionLeader "./result/bin/xpra" ["--fake-xinerama=no", "start", "--start", "./result/bin/xfce4-terminal", ":13"] (Just envListWithDisplay)
                    waitForXpraRecursively
        True -> do putStrLn "xpra is already running!"
      createSessionLeader "./result/bin/xpra" ["attach", ":13"] (Just envListWithDisplay)
      return ()
      where waitForXpraRecursively = do
              (_,output',_) <- B.readCreateProcessWithExitCode (shell "./result/bin/xpra list") ""
              let output = B.unpack output'
              putStrLn $ "Output is: " ++ output
              let isXpraAlreadyLive = isInfixOf ":13" output
              case isXpraAlreadyLive of
                False -> do putStrLn $ "Waiting for xpra server.."
                            waitForXpraRecursively
                True -> do putStrLn "xpra server found!"

createSessionLeader :: FilePath -> [String] -> Maybe [(String, String)] -> IO (ProcessID, ProcessGroupID)
createSessionLeader exe args env = do
  pid <- forkProcess $ do
    createSession
    executeFile exe True args env
  pgid <- getProcessGroupIDOf pid
  return (pid, pgid)

createProcessWithGroup :: ProcessGroupID -> FilePath -> [String] -> Maybe [(String, String)] -> IO ProcessID
createProcessWithGroup pgid exe args env =
   forkProcess $ do
    joinProcessGroup pgid
    executeFile exe True args env

launchHMDWebCam :: GodotSimulaServer -> IO ()
launchHMDWebCam gss = do
  maybePath <- getHMDWebCamPath
  case maybePath of
    Nothing -> putStrLn "Cannot find HMD web cam!"
    Just path  -> appLaunch gss "./result/bin/ffplay" ["-loglevel", "quiet", "-f", "v4l2", path]
    where getHMDWebCamPath :: IO (Maybe FilePath)
          getHMDWebCamPath = (listToMaybe . map ("/dev/v4l/by-id/" ++) . sort . filter viveOrValve) <$> listDirectory "/dev/v4l/by-id"
          viveOrValve :: String -> Bool
          viveOrValve str = any (`isInfixOf` str) ["Vive",  -- HTC Vive
                                                   "VIVE",  -- HTC Vive Pro
                                                   "Valve", -- Valve Index?
                                                   "Etron"] -- Valve Index

-- | HACK: `G.set_mouse_mode` is set to toggle the grab on *both* the keyboard and
-- | the mouse cursor.
toggleGrabMode :: IO ()
toggleGrabMode = do
  getSingleton GodotInput "Input" >>= \inp -> do
    mode <- G.get_mouse_mode inp
    case mode of
      G.MOUSE_MODE_CAPTURED -> G.set_mouse_mode inp G.MOUSE_MODE_VISIBLE
      G.MOUSE_MODE_VISIBLE -> G.set_mouse_mode inp G.MOUSE_MODE_CAPTURED
  return ()