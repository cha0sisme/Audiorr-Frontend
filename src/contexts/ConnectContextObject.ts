import { createContext } from 'react'
import type { ConnectContextType } from '../types/connect'

export const ConnectContext = createContext<ConnectContextType | undefined>(undefined)
