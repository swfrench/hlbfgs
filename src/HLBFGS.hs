{-# LANGUAGE ForeignFunctionInterface #-}
{-# CFILES driver.c #-}

-- | Haskell interface for the L-BFGS algorithm of Nocedal
module HLBFGS
( runSolver
) where

import Foreign.C
import Foreign.Ptr
import Foreign.ForeignPtr hiding (unsafeForeignPtrToPtr)
import Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)
import qualified Data.Vector.Storable as S

--------------------------------------------------------------------------------
-- Data types and aliases ------------------------------------------------------
--------------------------------------------------------------------------------

-- Convenient type alias
type Vec = S.Vector CDouble

-- Unit-like type representing foreign solver-state structure
data StateStruct = StateStruct

-- Convenient type alias for pointer to foreign structure
type StateStructPtr = Ptr StateStruct

-- Data type for putting it all together
data SolverConfig = SolverConfig CInt StateStructPtr deriving (Show)


foreign import ccall "initialize_solver" initWrapper
  :: CInt
  -> CInt
  -> CDouble
  -> Ptr CDouble
  -> IO StateStructPtr

foreign import ccall "finalize_solver" finalizeWrapper
  :: StateStructPtr
  -> IO ()

foreign import ccall "get_solution_vector" getInternalSolutionVector
  :: StateStructPtr
  -> IO (Ptr CDouble)

foreign import ccall "get_solution_vector_copy" getInternalSolutionVectorCopy
  :: StateStructPtr
  -> IO (Ptr CDouble)

foreign import ccall "&free_solution_vector_copy" freeSolutionVectorCopy
  :: FunPtr (Ptr CDouble -> IO ())

foreign import ccall "update_cost_and_gradient" updateInternalState
  :: StateStructPtr
  -> CDouble
  -> Ptr CDouble
  -> IO ()

foreign import ccall "iterate_solver" iterLBFGS
  :: StateStructPtr
  -> IO CInt

--------------------------------------------------------------------------------
-- Internal support routines ---------------------------------------------------
--------------------------------------------------------------------------------

initializeSolver
  :: CInt                     -- solution dimension @n@
  -> CInt                     -- memory dimension @m@
  -> CDouble                  -- tolerance @eps@
  -> Vec                      -- initial solution @x0@
  -> IO (Maybe SolverConfig)  -- returns: 'SolverConfig' on success
initializeSolver n m eps x0 = S.unsafeWith x0 (initWrapper n m eps) >>= wrap
  where wrap p =  if p == nullPtr
                  then return Nothing
                  else return . Just $ SolverConfig n p

finalizeSolverFailure
  :: SolverConfig
  -> IO ()
finalizeSolverFailure (SolverConfig _ p) = finalizeWrapper p

finalizeSolverSuccess
  :: SolverConfig
  -> IO Vec
finalizeSolverSuccess (SolverConfig n p) = do
  xsoln <- getInternalSolutionVectorCopy p >>= newForeignPtr freeSolutionVectorCopy >>= wrap
  finalizeWrapper p
  return xsoln
  where wrap fp = return $ S.unsafeFromForeignPtr0 fp (fromIntegral n)

getSolution
  :: SolverConfig
  -> IO Vec
getSolution (SolverConfig n p) =
  getInternalSolutionVector p >>= newForeignPtr_ >>= wrap
  where wrap fp = return $ S.unsafeFromForeignPtr0 fp (fromIntegral n)

updateSolverState
  :: SolverConfig
  -> CDouble
  -> Vec
  -> IO ()
updateSolverState (SolverConfig _ p) f gs =
  S.unsafeWith gs (updateInternalState p f)

iterateSolver
  :: SolverConfig
  -> IO CInt
iterateSolver (SolverConfig _ p) = iterLBFGS p

--------------------------------------------------------------------------------
-- The exported solver routine -------------------------------------------------
--------------------------------------------------------------------------------

-- | Minimize cost function @f@ w.r.t. @x@ using the L-BFGS algorithm
--
-- Returns @Nothing@ on initialization error (e.g. memory allocation) or
-- solution error.
runSolver
  :: CInt                   -- ^ solution dimension @n@
  -> CInt                   -- ^ memory dimension @m@
  -> CInt                   -- ^ max number of iters @niter@
  -> CDouble                -- ^ tolerance @eps@
  -> Vec                    -- ^ initial solution @x0@
  -> (Vec -> CDouble)       -- ^ const function @f@
  -> (Vec -> Vec)           -- ^ gradient function @g@
  -> IO (Maybe (CInt, Bool, Vec)) -- ^ returns: iter count, converged, solution or @Nothing@
runSolver n m niter eps x0 f g = initializeSolver n m eps x0 >>= run
  where run Nothing     = return Nothing
        run (Just conf) =
          let iter it iflag x =
                case iflag of
                  1 ->  if    it == niter
                        then  return . Just $ (it,iflag == 0,x)
                        else  do
                            updateSolverState conf (f x) (g x)
                            iflag <- iterateSolver conf
                            xcurr <- getSolution conf
                            iter (it+1) iflag xcurr

                  0 ->  do  xsoln <- finalizeSolverSuccess conf
                            return . Just $ (it,True,xsoln)

                  _ ->  do  finalizeSolverFailure conf
                            return Nothing
          in  iter 0 1 x0