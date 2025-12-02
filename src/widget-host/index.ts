// Widget Host - Main exports
export { WidgetHostProvider, useWidgetHost, WidgetRenderer } from './WidgetHost'
export { WidgetProcessManager, getWidgetProcessManager } from './WidgetProcessManager'
export type { WidgetProcess, WidgetProcessEvent } from './WidgetProcessManager'
export { WidgetDiscovery, getWidgetDiscovery, validateManifest } from './WidgetDiscovery'
export type { DiscoveredWidget, ManifestSchema } from './WidgetDiscovery'
