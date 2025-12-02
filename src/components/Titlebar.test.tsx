import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { Titlebar } from './Titlebar'

describe('Titlebar', () => {
  it('renders the titlebar with app name', () => {
    render(<Titlebar onToggleSidebar={vi.fn()} isSidebarOpen={false} />)

    expect(screen.getByText('Infinitty')).toBeInTheDocument()
    expect(screen.getByText('AI')).toBeInTheDocument()
  })

  it('displays collapsed indicator when sidebar is closed', () => {
    render(<Titlebar onToggleSidebar={vi.fn()} isSidebarOpen={false} />)

    const toggleButton = screen.getByRole('button', { name: /AI/ })
    expect(toggleButton).toHaveTextContent('>>')
  })

  it('displays expanded indicator when sidebar is open', () => {
    render(<Titlebar onToggleSidebar={vi.fn()} isSidebarOpen={true} />)

    const toggleButton = screen.getByRole('button', { name: /AI/ })
    expect(toggleButton).toHaveTextContent('<<')
  })

  it('calls onToggleSidebar when toggle button is clicked', async () => {
    const user = userEvent.setup()
    const onToggleSidebar = vi.fn()

    render(<Titlebar onToggleSidebar={onToggleSidebar} isSidebarOpen={false} />)

    const toggleButton = screen.getByRole('button', { name: /AI/ })
    await user.click(toggleButton)

    expect(onToggleSidebar).toHaveBeenCalledOnce()
  })

  it('applies correct color to toggle button when sidebar is open', () => {
    const { container } = render(
      <Titlebar onToggleSidebar={vi.fn()} isSidebarOpen={true} />
    )

    const toggleButton = container.querySelector('button')
    expect(toggleButton).toHaveStyle({ color: '#7aa2f7' })
  })

  it('applies correct color to toggle button when sidebar is closed', () => {
    const { container } = render(
      <Titlebar onToggleSidebar={vi.fn()} isSidebarOpen={false} />
    )

    const toggleButton = container.querySelector('button')
    expect(toggleButton).toHaveStyle({ color: '#565f89' })
  })

  it('has dragging enabled on header but disabled on button', () => {
    const { container } = render(
      <Titlebar onToggleSidebar={vi.fn()} isSidebarOpen={false} />
    )

    const header = container.querySelector('header') as HTMLElement
    const button = container.querySelector('button') as HTMLElement

    expect((header.style as any).WebkitAppRegion).toBe('drag')
    expect((button.style as any).WebkitAppRegion).toBe('no-drag')
  })

  it('renders header with correct background color', () => {
    const { container } = render(
      <Titlebar onToggleSidebar={vi.fn()} isSidebarOpen={false} />
    )

    const header = container.querySelector('header')
    expect(header).toHaveStyle({ backgroundColor: '#16161e' })
  })

  it('renders header with correct height', () => {
    const { container } = render(
      <Titlebar onToggleSidebar={vi.fn()} isSidebarOpen={false} />
    )

    const header = container.querySelector('header')
    expect(header).toHaveStyle({ height: '40px' })
  })
})
