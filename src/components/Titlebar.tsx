interface TitlebarProps {
  onToggleSidebar: () => void
  isSidebarOpen: boolean
}

export function Titlebar({ onToggleSidebar, isSidebarOpen }: TitlebarProps) {
  return (
    <header
      className="titlebar"
      style={{
        height: '40px',
        backgroundColor: '#16161e',
        borderBottom: '1px solid #292e42',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        padding: '0 12px',
        // Enable window dragging
        WebkitAppRegion: 'drag',
        userSelect: 'none',
      } as React.CSSProperties}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
        <button
          onClick={onToggleSidebar}
          style={{
            background: 'none',
            border: 'none',
            color: isSidebarOpen ? '#7aa2f7' : '#565f89',
            cursor: 'pointer',
            padding: '6px 8px',
            borderRadius: '4px',
            fontSize: '14px',
            display: 'flex',
            alignItems: 'center',
            gap: '6px',
            // Disable dragging on button
            WebkitAppRegion: 'no-drag',
          } as React.CSSProperties}
        >
          <span style={{ fontSize: '16px' }}>{isSidebarOpen ? '<<' : '>>'}</span>
          <span>AI</span>
        </button>
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
        <span style={{ fontSize: '13px', color: '#565f89' }}>Infinitty</span>
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
        <button
          style={{
            background: 'none',
            border: '1px solid #292e42',
            color: '#787c99',
            cursor: 'pointer',
            padding: '4px 10px',
            borderRadius: '4px',
            fontSize: '12px',
            WebkitAppRegion: 'no-drag',
          } as React.CSSProperties}
        >
          + New Tab
        </button>
      </div>
    </header>
  )
}
