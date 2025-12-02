/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_INTERFACE_MODE: 'ghostty' | 'openwarp'
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
