// Widget Tools Context - Allows widgets to register tools that can be called via AI/MCP
import { createContext, useContext, useState, useCallback, type ReactNode } from 'react'
import type { MCPTool } from '../types/mcp'

// Extended tool definition with handler
export interface WidgetTool extends MCPTool {
  handler: (args: Record<string, unknown>) => Promise<unknown>
  widgetId: string
  widgetType: string
}

interface WidgetToolsContextValue {
  // Get all registered tools
  tools: WidgetTool[]

  // Register a tool from a widget
  registerTool: (tool: WidgetTool) => void

  // Unregister a tool
  unregisterTool: (toolName: string, widgetId: string) => void

  // Unregister all tools from a widget
  unregisterWidgetTools: (widgetId: string) => void

  // Call a tool by name
  callTool: (toolName: string, args: Record<string, unknown>) => Promise<unknown>

  // Get tools for a specific widget
  getWidgetTools: (widgetId: string) => WidgetTool[]
}

const WidgetToolsContext = createContext<WidgetToolsContextValue | null>(null)

export function WidgetToolsProvider({ children }: { children: ReactNode }) {
  const [tools, setTools] = useState<WidgetTool[]>([])

  const registerTool = useCallback((tool: WidgetTool) => {
    setTools((prev) => {
      // Remove existing tool with same name from same widget
      const filtered = prev.filter(
        (t) => !(t.name === tool.name && t.widgetId === tool.widgetId)
      )
      return [...filtered, tool]
    })
    console.log(`[WidgetTools] Registered tool: ${tool.name} from widget ${tool.widgetId}`)
  }, [])

  const unregisterTool = useCallback((toolName: string, widgetId: string) => {
    setTools((prev) =>
      prev.filter((t) => !(t.name === toolName && t.widgetId === widgetId))
    )
    console.log(`[WidgetTools] Unregistered tool: ${toolName} from widget ${widgetId}`)
  }, [])

  const unregisterWidgetTools = useCallback((widgetId: string) => {
    setTools((prev) => {
      const remaining = prev.filter((t) => t.widgetId !== widgetId)
      console.log(`[WidgetTools] Unregistered all tools from widget ${widgetId}`)
      return remaining
    })
  }, [])

  const callTool = useCallback(async (toolName: string, args: Record<string, unknown>): Promise<unknown> => {
    const tool = tools.find((t) => t.name === toolName)
    if (!tool) {
      throw new Error(`Tool not found: ${toolName}`)
    }
    console.log(`[WidgetTools] Calling tool: ${toolName}`, args)
    return await tool.handler(args)
  }, [tools])

  const getWidgetTools = useCallback((widgetId: string): WidgetTool[] => {
    return tools.filter((t) => t.widgetId === widgetId)
  }, [tools])

  return (
    <WidgetToolsContext.Provider
      value={{
        tools,
        registerTool,
        unregisterTool,
        unregisterWidgetTools,
        callTool,
        getWidgetTools,
      }}
    >
      {children}
    </WidgetToolsContext.Provider>
  )
}

export function useWidgetTools() {
  const context = useContext(WidgetToolsContext)
  if (!context) {
    throw new Error('useWidgetTools must be used within a WidgetToolsProvider')
  }
  return context
}

// Hook for widgets to register their tools
export function useRegisterWidgetTool(
  widgetId: string,
  widgetType: string,
  tool: Omit<WidgetTool, 'widgetId' | 'widgetType'>
) {
  const { registerTool, unregisterTool } = useWidgetTools()

  // Register on mount, unregister on unmount
  const fullTool: WidgetTool = {
    ...tool,
    widgetId,
    widgetType,
  }

  // This effect runs on mount/unmount
  useState(() => {
    registerTool(fullTool)
    return () => unregisterTool(tool.name, widgetId)
  })
}
