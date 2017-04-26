module Simula.NewCompositor.Wayland.Output where

import Data.IORef
import Data.Word
import Data.Typeable
import Linear

import Graphics.Rendering.OpenGL hiding (Proxy)

import {-# SOURCE #-} Simula.NewCompositor.Event
import Simula.NewCompositor.Types

data WaylandSurfaceType = TopLevel | Transient | Popup | Cursor | NA
  deriving (Show, Eq, Ord, Enum)

data WaylandSurfaceClippingMode = None | Cuboid | Portal
  deriving (Show, Eq, Ord, Enum)

class (Eq a, Ord a, Typeable a) => WaylandSurface a where
  wsTexture :: a -> IO TextureObject
  wsSize :: a -> IO (V2 Int)
  setWsSize :: a -> V2 Int -> IO ()
  wsPosition :: a -> IO (V2 Int)
  wsParentSurface :: a -> IORef (Some WaylandSurface)
  wsPrepare :: a -> IO ()
  wsValid :: a -> IO Bool
  wsSendEvent :: a -> InputEvent -> IO ()

  wsType :: a -> IO WaylandSurfaceType
  setWsType :: a -> WaylandSurfaceType -> IO ()
  wsClippingMode :: a -> IO WaylandSurfaceClippingMode
  setWsClippingMode :: a -> WaylandSurfaceClippingMode -> IO ()

  wsDepthCompositingEnabled :: a -> IO Bool
  setWsDepthCompositingEnabled :: a -> Bool -> IO ()

  wsIsMotorcarSurface :: a -> IO Bool
  setWsIsMotorcarSurface :: a -> Bool -> IO ()
  
instance Eq (Some WaylandSurface) where
  Some a == Some b = case cast a of
    Just a -> a == b
    _ -> False

instance Ord (Some WaylandSurface) where
  Some (a :: a) <= Some (b :: b) = case cast a of
    Just a -> a <= b
    _ -> typeRep (Proxy :: Proxy a) <= typeRep (Proxy :: Proxy b)
