import React, { useState, useRef } from 'react';
import { createPortal } from 'react-dom';
import { useConnect } from '../hooks/useConnect';
import { Device } from '../types/connect';
import { ComputerDesktopIcon, DevicePhoneMobileIcon, TvIcon, ChevronRightIcon } from '@heroicons/react/24/outline';
import { motion } from 'framer-motion';
import { Capacitor } from '@capacitor/core';

// --- Premium Icons ---

const PremiumSpeakerIcon = ({ className }: { className?: string }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
    <rect x="5" y="3" width="14" height="18" rx="3" stroke="currentColor" strokeWidth="2" />
    <circle cx="12" cy="8" r="2.5" stroke="currentColor" strokeWidth="1.5" />
    <circle cx="12" cy="15" r="4" stroke="currentColor" strokeWidth="1.5" />
    <circle cx="12" cy="15" r="1.5" fill="currentColor" />
  </svg>
);

const GoogleHubIcon = ({ className }: { className?: string }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
    <path d="M4 5C4 3.89543 4.89543 3 6 3H18C19.1046 3 20 3.89543 20 5V13C20 14.1046 19.1046 15 18 15H6C4.89543 15 4 14.1046 4 13V5Z" stroke="currentColor" strokeWidth="2" />
    <path d="M7 15L6 21H18L17 15" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
    <path d="M9 21H15" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
  </svg>
);

export const DevicePicker: React.FC<{ align?: 'up' | 'down', buttonClassName?: string, iconClassName?: string, theme?: 'default' | 'player' }> = ({ align = 'down', buttonClassName, iconClassName, theme = 'default' }) => {
  const isPlayer = theme === 'player';
  const { devices, lanDevices, isConnected, isConnecting, currentDeviceId, transferPlayback, castToLanDevice, activeDeviceId, castSession, stopCast, reconnect } = useConnect();
  const [showPicker, setShowPicker] = useState(false);
  const [dropdownStyle, setDropdownStyle] = useState<React.CSSProperties>({});
  const isNativeIOS = Capacitor.isNativePlatform() && Capacitor.getPlatform() === 'ios';
  const buttonRef = useRef<HTMLButtonElement>(null);

  const handleToggle = () => {
    if (!showPicker && buttonRef.current) {
      const rect = buttonRef.current.getBoundingClientRect();
      const dropdownWidth = 288; // w-72
      const rightOffset = Math.max(8, window.innerWidth - rect.right);
      if (align === 'up') {
        setDropdownStyle({
          position: 'fixed',
          right: rightOffset,
          bottom: window.innerHeight - rect.top + 8,
          width: dropdownWidth,
        });
      } else {
        setDropdownStyle({
          position: 'fixed',
          right: rightOffset,
          top: rect.bottom + 8,
          width: dropdownWidth,
        });
      }
    }
    setShowPicker(prev => !prev);
  };

  const getDeviceIcon = (device: Device) => {
    const name = device.name.toLowerCase();
    if (name.includes('tv') || name.includes('smart tv') || device.lanType === 'display') {
      return <TvIcon className="w-5 h-5" />;
    }
    if (name.includes('hub') || name.includes('nest') || device.lanType === 'googlecast') {
      return <GoogleHubIcon className="w-5 h-5" />;
    }
    switch (device.type) {
      case 'receiver': return <PremiumSpeakerIcon className="w-5 h-5" />;
      case 'controller': return <DevicePhoneMobileIcon className="w-5 h-5" />;
      case 'lan_device':
        return <PremiumSpeakerIcon className="w-5 h-5 text-indigo-500" />;
      default:
        if (name.includes('iphone') || name.includes('android') || name.includes('mobile')) {
          return <DevicePhoneMobileIcon className="w-5 h-5" />;
        }
        return <ComputerDesktopIcon className="w-5 h-5" />;
    }
  };

  return (
    <div className="relative">
      <button
        ref={buttonRef}
        onClick={e => { e.stopPropagation(); handleToggle() }}
        className={`${buttonClassName || 'p-2'} rounded-full transition-all duration-200 ${
          activeDeviceId
            ? 'text-green-500 bg-green-500/10'
            : isConnected
              ? 'text-gray-600 dark:text-gray-400 hover:bg-gray-200 dark:hover:bg-gray-700'
              : 'text-gray-400 dark:text-gray-600 opacity-50'
        }`}
        title={isConnected ? "Seleccionar dispositivo" : "Conectando al Hub..."}
      >
        <div className="relative">
          <PremiumSpeakerIcon className={iconClassName || "w-6 h-6"} />
          {!isConnected && (
            <motion.div
              animate={{ opacity: [0, 1, 0] }}
              transition={{ repeat: Infinity, duration: 2 }}
              className="absolute -top-1 -right-1 w-2 h-2 bg-yellow-500 rounded-full"
            />
          )}
        </div>
      </button>

      {showPicker && createPortal(
          <>
            {/* Backdrop — captures taps outside on all platforms including iOS WKWebView */}
            <div
              className="fixed inset-0 z-[9998]"
              onClick={() => setShowPicker(false)}
            />

            {/* Dropdown */}
            <motion.div
              initial={{ opacity: 0, scale: 0.95, y: align === 'up' ? 8 : -8 }}
              animate={{ opacity: 1, scale: 1, y: 0 }}
              style={dropdownStyle}
              className={
                isPlayer
                  ? 'border border-white/10 rounded-2xl shadow-2xl z-[9999] overflow-hidden backdrop-blur-2xl'
                  : 'bg-white dark:bg-gray-900 border border-gray-200 dark:border-gray-800 rounded-2xl shadow-2xl z-[9999] overflow-hidden'
              }
              {...(isPlayer && { style: { ...dropdownStyle, background: 'rgba(18,18,18,0.96)' } })}
            >
              <div className="max-h-80 overflow-y-auto py-2">
                {!isConnected ? (
                  <div className="px-6 py-8 text-center flex flex-col items-center gap-3">
                    {isConnecting ? (
                      <div className={`w-8 h-8 border-2 rounded-full animate-spin ${isPlayer ? 'border-white/20 border-t-white/70' : 'border-gray-300 border-t-green-500'}`} />
                    ) : (
                      <div className="w-8 h-8 rounded-full bg-red-500/10 flex items-center justify-center">
                        <PremiumSpeakerIcon className="w-4 h-4 text-red-400" />
                      </div>
                    )}
                    <div>
                      <p className={`text-sm font-bold ${isPlayer ? 'text-white/80' : 'text-gray-700 dark:text-gray-200'}`}>
                        {isConnecting ? 'Localizando Hub...' : 'Sin conexión al Hub'}
                      </p>
                      <p className={`text-[10px] mt-1 ${isPlayer ? 'text-white/40' : 'text-gray-500 dark:text-gray-400'}`}>
                        {isConnecting
                          ? 'Conectando con el backend de Audiorr...'
                          : 'Asegúrate de que el backend está ejecutándose en tu red local.'}
                      </p>
                    </div>
                    {!isConnecting && (
                      <button
                        onClick={() => reconnect()}
                        className={`mt-2 px-4 py-1.5 rounded-lg text-xs font-semibold transition-colors ${
                          isPlayer
                            ? 'bg-white/10 hover:bg-white/20 text-white/70'
                            : 'bg-gray-200 hover:bg-gray-300 dark:bg-gray-700 dark:hover:bg-gray-600 text-gray-700 dark:text-gray-200'
                        }`}
                      >
                        Reintentar
                      </button>
                    )}
                  </div>
                ) : (
                  <>
                    <button
                      className={`w-full flex items-center gap-3 px-4 py-3 text-left transition-colors ${
                        !activeDeviceId || activeDeviceId === currentDeviceId
                          ? isPlayer ? 'bg-green-500/15 text-green-400' : 'bg-green-500/10 text-green-500'
                          : isPlayer ? 'hover:bg-white/8 text-white/70' : 'hover:bg-gray-50 dark:hover:bg-gray-800 text-gray-700 dark:text-gray-300'
                      }`}
                      onClick={() => {
                        transferPlayback(currentDeviceId);
                        setShowPicker(false);
                      }}
                    >
                      <div className={`p-2 rounded-lg ${
                        !activeDeviceId || activeDeviceId === currentDeviceId
                          ? 'bg-green-500/20 text-green-400'
                          : isPlayer ? 'bg-white/10 text-white/40' : 'bg-gray-100 dark:bg-gray-800 text-gray-400 dark:text-gray-500'
                      }`}>
                        {isNativeIOS
                          ? <DevicePhoneMobileIcon className="w-5 h-5" />
                          : <ComputerDesktopIcon className="w-5 h-5" />}
                      </div>
                      <div className="flex-1 overflow-hidden">
                        <p className="font-semibold text-sm truncate">
                          {isNativeIOS ? 'Este iPhone' : 'Este equipo'}
                        </p>
                        <p className={`text-xs ${(!activeDeviceId || activeDeviceId === currentDeviceId) ? 'text-green-400/80' : isPlayer ? 'text-white/35' : 'text-gray-500 dark:text-gray-400'}`}>
                          {!activeDeviceId || activeDeviceId === currentDeviceId ? 'En reproducción aquí' : 'Disponible'}
                        </p>
                      </div>
                    </button>

                    {devices.filter(d => d.id !== currentDeviceId).length > 0 && (
                      <>
                        {devices
                          .filter(d => d.id !== currentDeviceId)
                          .map(device => (
                            <button
                              key={device.id}
                              className={`w-full flex items-center gap-3 px-4 py-3 text-left transition-colors ${
                                activeDeviceId === device.id
                                  ? isPlayer ? 'bg-green-500/15 text-green-400' : 'bg-green-500/10 text-green-500'
                                  : isPlayer ? 'hover:bg-white/8 text-white/70' : 'hover:bg-gray-50 dark:hover:bg-gray-800 text-gray-700 dark:text-gray-300'
                              }`}
                              onClick={() => {
                                transferPlayback(device.id);
                                setShowPicker(false);
                              }}
                            >
                              <div className={`p-2 rounded-lg ${
                                activeDeviceId === device.id
                                  ? 'bg-green-500/20 text-green-400'
                                  : isPlayer ? 'bg-white/10 text-white/40' : 'bg-gray-100 dark:bg-gray-800 text-gray-400 dark:text-gray-500'
                              }`}>
                                {getDeviceIcon(device)}
                              </div>
                              <div className="flex-1 overflow-hidden">
                                <p className="font-semibold text-sm truncate">{device.name}</p>
                                <p className={`text-xs ${activeDeviceId === device.id ? 'text-green-400/80' : isPlayer ? 'text-white/35' : 'text-gray-500 dark:text-gray-400'}`}>
                                  {device.type === 'receiver' ? 'Audiorr Receiver' : activeDeviceId === device.id ? 'En reproducción aquí' : 'Conectado'}
                                </p>
                              </div>
                              <ChevronRightIcon className={`w-4 h-4 ${isPlayer ? 'opacity-20' : 'opacity-30'}`} />
                            </button>
                          ))}
                      </>
                    )}

                    {castSession.active && (
                      <div className={`mx-3 mt-2 mb-1 p-3 rounded-xl flex items-center gap-3 ${isPlayer ? 'bg-indigo-500/15 border border-indigo-400/20' : 'bg-indigo-500/10 border border-indigo-500/20'}`}>
                        <div className="flex-1 min-w-0">
                          <p className={`text-xs font-bold truncate ${isPlayer ? 'text-indigo-300' : 'text-indigo-600 dark:text-indigo-400'}`}>
                            Reproduciendo en {castSession.deviceName}
                          </p>
                          <p className="text-[10px] text-indigo-400/60 mt-0.5">Google Cast activo</p>
                        </div>
                        <button
                          onClick={() => { stopCast(); setShowPicker(false); }}
                          className="shrink-0 text-[10px] bg-indigo-500 text-white px-2 py-1 rounded-lg hover:bg-indigo-600 transition-colors font-bold"
                        >
                          Detener
                        </button>
                      </div>
                    )}

                    {lanDevices.length > 0 && (
                      <>
                        <div className={`px-4 py-2 mt-2 text-[10px] font-bold uppercase tracking-widest ${isPlayer ? 'text-white/25' : 'text-indigo-400'}`}>
                          Dispositivos LAN (Cast)
                        </div>
                        {lanDevices.map(device => {
                          const isCastingHere = castSession.active && castSession.deviceId === device.id;
                          return (
                            <button
                              key={device.id}
                              className={`w-full flex items-center gap-3 px-4 py-3 text-left transition-colors ${
                                isCastingHere
                                  ? isPlayer ? 'bg-indigo-500/15 text-indigo-300' : 'bg-indigo-500/10 text-indigo-500'
                                  : isPlayer ? 'hover:bg-white/8 text-white/70' : 'hover:bg-gray-50 dark:hover:bg-gray-800 text-gray-700 dark:text-gray-300'
                              }`}
                              onClick={() => {
                                castToLanDevice(device);
                                setShowPicker(false);
                              }}
                            >
                              <div className={`p-2 rounded-lg ${isPlayer ? 'bg-indigo-500/15' : 'bg-indigo-500/10'}`}>
                                {getDeviceIcon(device)}
                              </div>
                              <div className="flex-1 overflow-hidden">
                                <p className={`font-semibold text-sm truncate ${isPlayer ? 'text-indigo-300' : 'text-indigo-600 dark:text-indigo-400'}`}>{device.name}</p>
                                <p className={`text-[10px] font-mono ${isPlayer ? 'text-white/30' : 'text-gray-500 dark:text-gray-400'}`}>
                                  {isCastingHere ? 'Reproduciendo ahora' : `${device.lanType} · ${device.ip}`}
                                </p>
                              </div>
                              {isCastingHere
                                ? <span className="text-[10px] bg-indigo-500 text-white px-1.5 py-0.5 rounded uppercase font-bold animate-pulse">Live</span>
                                : <span className={`text-[10px] px-1.5 py-0.5 rounded uppercase font-bold ${isPlayer ? 'bg-white/10 text-white/50' : 'bg-indigo-500/20 text-indigo-600'}`}>Cast</span>
                              }
                            </button>
                          );
                        })}
                      </>
                    )}

                    {devices.filter(d => d.id !== currentDeviceId).length === 0 && lanDevices.length === 0 && (
                      <div className="px-6 py-8 text-center">
                        <p className={`text-sm ${isPlayer ? 'text-white/35' : 'text-gray-400'}`}>Buscando otros dispositivos...</p>
                        <p className={`text-[10px] mt-2 ${isPlayer ? 'text-white/25' : 'text-gray-500'}`}>
                          Abre Audiorr en otro móvil o PC para verlo aquí.
                        </p>
                      </div>
                    )}
                  </>
                )}
              </div>
            </motion.div>
          </>,
          document.body
        )}
    </div>
  );
};
