// Example Chart Widget - Shows how to build widgets with the SDK
// NOTE: In a real external widget package, you'd import from '@infinitty/widget-sdk'
// For this example in the monorepo, we use relative paths
import { useEffect, useRef, useState } from 'react'
import {
  defineWidget,
  useTheme,
  useConfig,
  useTool,
  useCommand,
  useMessage,
  useBroadcast,
  useWidgetSDK,
  hexToRgba,
} from '../../widget-sdk'
import type { WidgetComponentProps } from '../../widget-sdk'

// ============================================
// Widget Configuration Types
// ============================================

interface ChartConfig {
  defaultType?: 'line' | 'bar' | 'pie' | 'scatter'
  animate?: boolean
  theme?: 'auto' | 'light' | 'dark'
  refreshIntervalMs?: number
  historyPoints?: number
}

interface ChartData {
  labels: string[]
  datasets: {
    label: string
    data: number[]
    color?: string
  }[]
}

// ============================================
// Chart Component
// ============================================

function ChartWidget({ api }: WidgetComponentProps) {
  const theme = useTheme()
  const config = useConfig<ChartConfig>()
  const { context: { log } } = useWidgetSDK()

  const [chartType, setChartType] = useState(config.defaultType ?? 'line')
  const historyPoints = config.historyPoints ?? 60
  const refreshIntervalMs = config.refreshIntervalMs ?? 1000

  const [chartData, setChartData] = useState<ChartData>({
    labels: Array.from({ length: historyPoints }, (_, i) => `${historyPoints - i}s`),
    datasets: [
      { label: 'CPU %', data: Array(historyPoints).fill(0), color: theme.cyan },
      { label: 'Memory %', data: Array(historyPoints).fill(0), color: theme.magenta },
      { label: 'Disk %', data: Array(historyPoints).fill(0), color: theme.yellow },
    ],
  })

  const tickRef = useRef(0)

  useEffect(() => {
    let stopped = false
    const updateOnce = async () => {
      try {
        const result = await api.executeCommand('tauri:invoke', 'get_system_metrics') as {
          cpu_usage: number
          memory_used_mb: number
          memory_total_mb: number
          disk_used_mb: number
          disk_total_mb: number
        }

        const cpu = result.cpu_usage
        const memPct = result.memory_total_mb > 0
          ? (result.memory_used_mb / result.memory_total_mb) * 100
          : 0
        const diskPct = result.disk_total_mb > 0
          ? (result.disk_used_mb / result.disk_total_mb) * 100
          : 0

        tickRef.current += 1
        const label = `${tickRef.current * refreshIntervalMs / 1000}s`

        setChartData(prev => {
          const nextLabels = [...prev.labels.slice(1), label]
          const nextDatasets = prev.datasets.map(ds => {
            const val = ds.label.startsWith('CPU') ? cpu : ds.label.startsWith('Memory') ? memPct : diskPct
            return { ...ds, data: [...ds.data.slice(1), Math.round(val * 10) / 10] }
          })
          return { labels: nextLabels, datasets: nextDatasets }
        })
      } catch (err) {
        log.warn('Failed to fetch system metrics', err)
      }
    }

    const interval = setInterval(() => {
      if (!stopped) updateOnce()
    }, refreshIntervalMs)
    updateOnce()

    return () => {
      stopped = true
      clearInterval(interval)
    }
  }, [api, log, refreshIntervalMs])

  // Register tool: chart_create
  useTool(
    {
      name: 'chart_create',
      description: 'Create a new chart with data',
      inputSchema: {
        type: 'object',
        properties: {
          type: { type: 'string', enum: ['line', 'bar', 'pie', 'scatter'] },
          data: { type: 'object' },
          title: { type: 'string' },
        },
        required: ['type', 'data'],
      },
    },
    async (args) => {
      const { type, data, title } = args as {
        type: typeof chartType
        data: ChartData
        title?: string
      }

      log.info('Creating chart:', { type, title })
      setChartType(type)
      setChartData(data)

      return { success: true, message: `Created ${type} chart` }
    }
  )

  // Register tool: chart_update
  useTool(
    {
      name: 'chart_update',
      description: 'Update chart data',
      inputSchema: {
        type: 'object',
        properties: {
          data: { type: 'object' },
        },
        required: ['data'],
      },
    },
    async (args) => {
      const { data } = args as { data: Partial<ChartData> }
      setChartData((prev) => ({ ...prev, ...data }))
      return { success: true }
    }
  )

  // Register command: chart.create
  useCommand('chart.create', () => {
    api.showMessage('Opening chart creator...', 'info')
    // Show chart creation dialog
  })

  // Register command: chart.export
  useCommand('chart.export', async () => {
    api.showMessage('Exporting chart...', 'info')
    // Export chart as PNG
  })

  // Listen for messages from other widgets
  useMessage<{ action: string; data: unknown }>((msg) => {
    log.debug('Received message:', msg)
    if (msg.action === 'updateData') {
      setChartData(msg.data as ChartData)
    }
  })

  // Listen for broadcast on 'data-update' channel
  useBroadcast<{ chartData: ChartData }>('data-update', (msg) => {
    if (msg.chartData) {
      setChartData(msg.chartData)
    }
  })

  // Calculate chart dimensions
  const maxValue = Math.max(...chartData.datasets.flatMap((d) => d.data))
  const chartHeight = 200
  const barWidth = 100 / chartData.labels.length

  return (
    <div
      style={{
        height: '100%',
        display: 'flex',
        flexDirection: 'column',
        backgroundColor: theme.background,
        color: theme.foreground,
        padding: 16,
      }}
    >
      {/* Toolbar */}
      <div
        style={{
          display: 'flex',
          gap: 8,
          marginBottom: 16,
          flexShrink: 0,
        }}
      >
        {(['line', 'bar', 'pie', 'scatter'] as const).map((type) => (
          <button
            key={type}
            onClick={() => setChartType(type)}
            style={{
              padding: '6px 12px',
              backgroundColor:
                chartType === type
                  ? hexToRgba(theme.cyan, 0.2)
                  : hexToRgba(theme.brightBlack, 0.1),
              border: `1px solid ${chartType === type ? theme.cyan : theme.brightBlack}40`,
              borderRadius: 6,
              color: chartType === type ? theme.cyan : theme.foreground,
              cursor: 'pointer',
              fontSize: 12,
              textTransform: 'capitalize',
            }}
          >
            {type}
          </button>
        ))}
      </div>

      {/* Chart Area */}
      <div
        style={{
          flex: 1,
          border: `1px solid ${theme.brightBlack}40`,
          borderRadius: 8,
          padding: 16,
          display: 'flex',
          flexDirection: 'column',
        }}
      >
        {/* Simple Bar Chart Visualization */}
        {chartType === 'bar' && (
          <div
            style={{
              flex: 1,
              display: 'flex',
              alignItems: 'flex-end',
              justifyContent: 'space-around',
              paddingBottom: 30,
              position: 'relative',
            }}
          >
            {chartData.labels.map((label, i) => (
              <div
                key={label}
                style={{
                  display: 'flex',
                  flexDirection: 'column',
                  alignItems: 'center',
                  width: `${barWidth - 2}%`,
                }}
              >
                <div style={{ display: 'flex', gap: 4, alignItems: 'flex-end' }}>
                  {chartData.datasets.map((dataset, j) => (
                    <div
                      key={j}
                      style={{
                        width: 20,
                        height: `${(dataset.data[i] / maxValue) * chartHeight}px`,
                        backgroundColor: dataset.color ?? theme.cyan,
                        borderRadius: '4px 4px 0 0',
                        transition: config.animate ? 'height 0.3s ease' : 'none',
                      }}
                    />
                  ))}
                </div>
                <span
                  style={{
                    marginTop: 8,
                    fontSize: 11,
                    color: theme.brightBlack,
                  }}
                >
                  {label}
                </span>
              </div>
            ))}
          </div>
        )}

        {/* Line Chart Placeholder */}
        {chartType === 'line' && (
          <div
            style={{
              flex: 1,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              color: theme.brightBlack,
            }}
          >
            <svg width="100%" height="100%" viewBox="0 0 400 200">
              {chartData.datasets.map((dataset, i) => {
                const points = dataset.data
                  .map((val, j) => {
                    const x = (j / (dataset.data.length - 1)) * 380 + 10
                    const y = 190 - (val / maxValue) * 170
                    return `${x},${y}`
                  })
                  .join(' ')
                return (
                  <polyline
                    key={i}
                    points={points}
                    fill="none"
                    stroke={dataset.color ?? theme.cyan}
                    strokeWidth={2}
                    style={{
                      transition: config.animate ? 'all 0.3s ease' : 'none',
                    }}
                  />
                )
              })}
            </svg>
          </div>
        )}

        {/* Pie Chart Placeholder */}
        {chartType === 'pie' && (
          <div
            style={{
              flex: 1,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
            }}
          >
            <svg width="200" height="200" viewBox="0 0 200 200">
              {(() => {
                const total = chartData.datasets[0]?.data.reduce((a, b) => a + b, 0) ?? 0
                let currentAngle = 0
                const colors = [theme.cyan, theme.magenta, theme.yellow, theme.green, theme.red]

                return chartData.datasets[0]?.data.map((val, i) => {
                  const angle = (val / total) * 360
                  const startAngle = currentAngle
                  const endAngle = currentAngle + angle
                  currentAngle = endAngle

                  const startRad = (startAngle - 90) * (Math.PI / 180)
                  const endRad = (endAngle - 90) * (Math.PI / 180)
                  const largeArc = angle > 180 ? 1 : 0

                  const x1 = 100 + 80 * Math.cos(startRad)
                  const y1 = 100 + 80 * Math.sin(startRad)
                  const x2 = 100 + 80 * Math.cos(endRad)
                  const y2 = 100 + 80 * Math.sin(endRad)

                  return (
                    <path
                      key={i}
                      d={`M 100 100 L ${x1} ${y1} A 80 80 0 ${largeArc} 1 ${x2} ${y2} Z`}
                      fill={colors[i % colors.length]}
                      opacity={0.8}
                    />
                  )
                })
              })()}
            </svg>
          </div>
        )}

        {/* Scatter Chart Placeholder */}
        {chartType === 'scatter' && (
          <div
            style={{
              flex: 1,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
            }}
          >
            <svg width="100%" height="100%" viewBox="0 0 400 200">
              {chartData.datasets.map((dataset, i) => (
                <g key={i}>
                  {dataset.data.map((val, j) => (
                    <circle
                      key={j}
                      cx={(j / (dataset.data.length - 1)) * 380 + 10}
                      cy={190 - (val / maxValue) * 170}
                      r={6}
                      fill={dataset.color ?? theme.cyan}
                      opacity={0.8}
                    />
                  ))}
                </g>
              ))}
            </svg>
          </div>
        )}
      </div>

      {/* Legend */}
      <div
        style={{
          display: 'flex',
          gap: 16,
          marginTop: 12,
          justifyContent: 'center',
        }}
      >
        {chartData.datasets.map((dataset, i) => (
          <div
            key={i}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 6,
            }}
          >
            <div
              style={{
                width: 12,
                height: 12,
                borderRadius: 2,
                backgroundColor: dataset.color ?? theme.cyan,
              }}
            />
            <span style={{ fontSize: 12, color: theme.foreground }}>
              {dataset.label}
            </span>
          </div>
        ))}
      </div>
    </div>
  )
}

// ============================================
// Widget Definition
// ============================================

export default defineWidget({
  id: 'com.infinitty.chart-widget',
  name: 'System Monitor',
  version: '1.0.0',
  description: 'Live CPU, memory, and disk usage monitor',

  activate: (context) => {
    context.log.info('Chart widget activated')
    // Register activation-time tools/commands if needed
  },

  deactivate: () => {
    console.log('Chart widget deactivated')
  },

  Component: ChartWidget,
})
