/**
 * Dev entry point - runs widget in standalone simulator
 *
 * Run: npm run dev
 */

import { createDevSimulator } from '@infinitty/widget-sdk/dev-simulator'
import widget from './index'

// Start the dev simulator with your widget
createDevSimulator(widget, {
  widgetId: '{{WIDGET_ID}}',
  theme: 'dark',
  config: {
    // Add default config values for testing
    exampleOption: 'test value',
  },
  devTools: true,
})
