/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_APP_VERSION?: string
  readonly VITE_APP_BUILD?: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}

declare const __APP_COMMIT__: string
declare const __BUILD_DATE__: string
declare const __BUILD_ID__: string


