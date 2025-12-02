// Widget SDK Core - Widget definition and event system
import type {
  WidgetModule,
  WidgetContext,
  WidgetHostAPI,
  WidgetEvents,
  EventEmitter,
  Event,
  Disposable,
  WidgetComponentProps,
} from './types'

// ============================================
// Event Emitter Implementation
// ============================================

export function createEventEmitter<T>(): EventEmitter<T> {
  const listeners: Set<(e: T) => void> = new Set()

  const event: Event<T> = (listener) => {
    listeners.add(listener)
    return {
      dispose: () => {
        listeners.delete(listener)
      },
    }
  }

  const fire = (data: T) => {
    listeners.forEach((listener) => {
      try {
        listener(data)
      } catch (error) {
        console.error('Event listener error:', error)
      }
    })
  }

  const dispose = () => {
    listeners.clear()
  }

  return { event, fire, dispose }
}

// ============================================
// Widget Definition Helper
// ============================================

interface WidgetDefinition {
  id: string
  name: string
  version: string
  description?: string
  activate?: (context: WidgetContext, api: WidgetHostAPI, events: WidgetEvents) => void | Promise<void>
  deactivate?: () => void | Promise<void>
  Component?: React.ComponentType<WidgetComponentProps>
}

export function defineWidget(definition: WidgetDefinition): WidgetModule {
  return {
    activate: definition.activate ?? (() => {}),
    deactivate: definition.deactivate,
    Component: definition.Component,
  }
}

// ============================================
// Disposable Helpers
// ============================================

export function toDisposable(fn: () => void): Disposable {
  return { dispose: fn }
}

export class DisposableStore implements Disposable {
  private disposables: Disposable[] = []
  private isDisposed = false

  add<T extends Disposable>(disposable: T): T {
    if (this.isDisposed) {
      disposable.dispose()
    } else {
      this.disposables.push(disposable)
    }
    return disposable
  }

  dispose(): void {
    if (!this.isDisposed) {
      this.isDisposed = true
      this.disposables.forEach((d) => d.dispose())
      this.disposables = []
    }
  }
}

// ============================================
// Deferred Promise
// ============================================

export interface DeferredPromise<T> {
  promise: Promise<T>
  resolve: (value: T) => void
  reject: (error: unknown) => void
}

export function createDeferredPromise<T>(): DeferredPromise<T> {
  let resolve!: (value: T) => void
  let reject!: (error: unknown) => void

  const promise = new Promise<T>((res, rej) => {
    resolve = res
    reject = rej
  })

  return { promise, resolve, reject }
}

// ============================================
// Throttle and Debounce
// ============================================

export function throttle<T extends (...args: unknown[]) => void>(
  fn: T,
  limit: number
): T {
  let inThrottle = false
  return ((...args: unknown[]) => {
    if (!inThrottle) {
      fn(...args)
      inThrottle = true
      setTimeout(() => {
        inThrottle = false
      }, limit)
    }
  }) as T
}

export function debounce<T extends (...args: unknown[]) => void>(
  fn: T,
  delay: number
): T {
  let timeoutId: ReturnType<typeof setTimeout>
  return ((...args: unknown[]) => {
    clearTimeout(timeoutId)
    timeoutId = setTimeout(() => fn(...args), delay)
  }) as T
}
