import { useContext } from 'react'
import { ConnectContext } from '../contexts/ConnectContextObject'

export const useConnect = () => {
  const context = useContext(ConnectContext)
  if (!context) throw new Error('useConnect must be used within ConnectProvider')
  return context
}
