export interface Device {
  id: string;
  name: string;
  type: 'controller' | 'receiver' | 'hybrid' | 'lan_device' | 'casting';
  lastSeen?: number;
  ip?: string;
  port?: number;
  lanType?: string;
}

export interface PlaybackMetadata {
  title: string;
  artist: string;
  album: string;
  coverArt?: string;
  duration: number;
}

export interface PlaybackState {
  trackId: string | null;
  metadata?: PlaybackMetadata | null;
  position: number;
  startedAt: number;
  playing: boolean;
  volume: number;
  queue: PlaybackQueueItem[];
  currentSource: string | null;
  deviceId: string;
  serverTime?: number;
}

/** Song-like shape for items in the remote queue (matches Song from navidromeApi) */
export interface PlaybackQueueItem {
  id: string;
  title: string;
  artist: string;
  album: string;
  duration: number;
  path: string;
  coverArt?: string;
  albumId?: string;
  [key: string]: unknown;
}

export interface RemoteCommand {
  action: string;
  value: unknown;
  targetDeviceId?: string;
}

export interface CastSession {
  active: boolean;
  deviceId?: string;
  deviceName?: string;
}

export interface ConnectContextType {
  isConnected: boolean;
  isConnecting: boolean;
  devices: Device[];
  lanDevices: Device[];
  currentDeviceId: string;
  remotePlaybackState: PlaybackState | null;
  activeDeviceId: string | null;
  isReceiverMode: boolean;
  lastError: string | null;
  connectUrl: string;
  castSession: CastSession;
  setReceiverMode: (enabled: boolean) => void;
  transferPlayback: (targetDeviceId: string) => void;
  castToLanDevice: (device: Device) => void;
  sendRemoteCommand: (action: string, value: unknown, targetDeviceId?: string) => void;
  stopCast: () => void;
  reconnect: () => void;
  subscribeToEvent: (event: string, handler: (data: unknown) => void) => () => void;
}
