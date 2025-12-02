/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        // Warp dark theme colors
        warp: {
          bg: '#0d1117',
          'bg-secondary': '#161b22',
          'bg-tertiary': '#21262d',
          sidebar: '#0b0d12', // Darker sidebar
          input: '#12161f',   // Input field specific
          border: '#30363d',
          'border-light': '#484f58',
          text: '#c9d1d9',
          'text-secondary': '#8b949e',
          'text-muted': '#6e7681',
          accent: '#58a6ff',
          'accent-hover': '#79c0ff',
          green: '#3fb950',
          yellow: '#d29922',
          red: '#f85149',
          purple: '#a371f7',
        }
      },
      fontFamily: {
        mono: ['JetBrains Mono', 'Menlo', 'Monaco', 'Consolas', 'monospace'],
        serif: ['ui-serif', 'Georgia', 'Cambria', '"Times New Roman"', 'Times', 'serif'],
      },
    },
  },
  plugins: [],
}
