import { useEffect, useState, useRef } from 'react'
import { useTerminalSettings } from '../contexts/TerminalSettingsContext'

interface PerformanceStats {
  fps: number
  memory: {
    used: number
    total: number
  } | null
  cpuUsage: number | null
}

export function DebugStats() {
  const { settings } = useTerminalSettings()
  const theme = settings.theme
  const [stats, setStats] = useState<PerformanceStats>({
    fps: 0,
    memory: null,
    cpuUsage: null,
  })

  const frameCountRef = useRef(0)
  const lastTimeRef = useRef(performance.now())
  const rafIdRef = useRef<number>(0)

  useEffect(() => {
    // FPS calculation
    const measureFPS = () => {
      frameCountRef.current++
      const currentTime = performance.now()
      const elapsed = currentTime - lastTimeRef.current

      if (elapsed >= 1000) {
        const fps = Math.round((frameCountRef.current * 1000) / elapsed)
        frameCountRef.current = 0
        lastTimeRef.current = currentTime

        // Memory usage (Chrome only)
        let memory: PerformanceStats['memory'] = null
        // @ts-expect-error - Chrome-specific API
        if (performance.memory) {
          // @ts-expect-error - Chrome-specific API
          const memInfo = performance.memory
          memory = {
            used: Math.round(memInfo.usedJSHeapSize / 1024 / 1024),
            total: Math.round(memInfo.totalJSHeapSize / 1024 / 1024),
          }
        }

        setStats(prev => ({
          ...prev,
          fps,
          memory,
        }))
      }

      rafIdRef.current = requestAnimationFrame(measureFPS)
    }

    rafIdRef.current = requestAnimationFrame(measureFPS)

    return () => {
      if (rafIdRef.current) {
        cancelAnimationFrame(rafIdRef.current)
      }
    }
  }, [])

  const getFPSColor = (fps: number): string => {
    if (fps >= 55) return theme.green
    if (fps >= 30) return theme.yellow
    return theme.red
  }

  const getMemoryColor = (used: number, total: number): string => {
    const ratio = used / total
    if (ratio < 0.6) return theme.green
    if (ratio < 0.8) return theme.yellow
    return theme.red
  }

  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: '16px',
        fontSize: '10px',
        fontFamily: 'monospace',
        color: theme.white,
        opacity: 0.8,
      }}
    >
      {/* FPS */}
      <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
        <span style={{ opacity: 0.6 }}>FPS</span>
        <span style={{ color: getFPSColor(stats.fps), fontWeight: 600 }}>
          {stats.fps}
        </span>
      </div>

      {/* Memory */}
      {stats.memory && (
        <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
          <span style={{ opacity: 0.6 }}>MEM</span>
          <span
            style={{
              color: getMemoryColor(stats.memory.used, stats.memory.total),
              fontWeight: 600,
            }}
          >
            {stats.memory.used}MB
          </span>
          <span style={{ opacity: 0.4 }}>/ {stats.memory.total}MB</span>
        </div>
      )}

      {/* JS Heap indicator */}
      <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
        <span style={{ opacity: 0.6 }}>HEAP</span>
        <div
          style={{
            width: '40px',
            height: '4px',
            backgroundColor: `${theme.white}20`,
            borderRadius: '2px',
            overflow: 'hidden',
          }}
        >
          {stats.memory && (
            <div
              style={{
                width: `${(stats.memory.used / stats.memory.total) * 100}%`,
                height: '100%',
                backgroundColor: getMemoryColor(stats.memory.used, stats.memory.total),
                transition: 'width 0.3s ease',
              }}
            />
          )}
        </div>
      </div>
    </div>
  )
}
