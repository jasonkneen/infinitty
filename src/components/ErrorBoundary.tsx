import { Component, type ReactNode } from 'react'

interface ErrorBoundaryProps {
  children: ReactNode
  fallback?: ReactNode
}

interface ErrorBoundaryState {
  hasError: boolean
  error: Error | null
}

export class ErrorBoundary extends Component<ErrorBoundaryProps, ErrorBoundaryState> {
  constructor(props: ErrorBoundaryProps) {
    super(props)
    this.state = { hasError: false, error: null }
  }

  static getDerivedStateFromError(error: Error): ErrorBoundaryState {
    return { hasError: true, error }
  }

  componentDidCatch(error: Error, errorInfo: React.ErrorInfo): void {
    // Log error for debugging (sanitized - no full stack in production)
    console.error('[ErrorBoundary] Caught error:', error.message)
    console.error('[ErrorBoundary] Component stack:', errorInfo.componentStack)
  }

  handleReset = (): void => {
    this.setState({ hasError: false, error: null })
  }

  render(): ReactNode {
    if (this.state.hasError) {
      if (this.props.fallback) {
        return this.props.fallback
      }

      return (
        <div
          style={{
            display: 'flex',
            flexDirection: 'column',
            alignItems: 'center',
            justifyContent: 'center',
            padding: '40px 20px',
            backgroundColor: '#1a1b26',
            borderRadius: '12px',
            border: '1px solid #292e42',
            margin: '20px',
          }}
        >
          <div
            style={{
              width: '48px',
              height: '48px',
              borderRadius: '50%',
              backgroundColor: 'rgba(247, 118, 142, 0.1)',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              marginBottom: '16px',
            }}
          >
            <span style={{ fontSize: '24px' }}>⚠️</span>
          </div>
          <h3
            style={{
              color: '#c0caf5',
              fontSize: '16px',
              fontWeight: 600,
              marginBottom: '8px',
            }}
          >
            Something went wrong
          </h3>
          <p
            style={{
              color: '#7a82a6',
              fontSize: '14px',
              textAlign: 'center',
              marginBottom: '20px',
              maxWidth: '300px',
            }}
          >
            An error occurred while rendering this component.
          </p>
          <button
            onClick={this.handleReset}
            style={{
              padding: '8px 16px',
              backgroundColor: '#2dd4bf',
              color: '#0a0e16',
              border: 'none',
              borderRadius: '6px',
              fontSize: '14px',
              fontWeight: 500,
              cursor: 'pointer',
            }}
          >
            Try Again
          </button>
        </div>
      )
    }

    return this.props.children
  }
}
