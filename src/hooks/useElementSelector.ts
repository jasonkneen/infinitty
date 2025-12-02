import { useCallback, useState } from 'react'
import { invoke } from '@tauri-apps/api/core'

// The script that gets injected into webviews for element selection
const ELEMENT_SELECTOR_SCRIPT = `
(function() {
  if (window.__infinittyElementSelector) {
    window.__infinittyElementSelector.toggle();
    return;
  }

  const state = {
    active: false,
    hoveredElement: null,
    selectedElement: null,
    overlay: null,
    infoBox: null,
  };

  function createOverlay() {
    const overlay = document.createElement('div');
    overlay.id = '__infinitty-overlay';
    overlay.style.cssText = \`
      position: fixed;
      pointer-events: none;
      z-index: 999999;
      border: 2px solid #00d9ff;
      background: rgba(0, 217, 255, 0.1);
      transition: all 0.1s ease;
    \`;
    document.body.appendChild(overlay);
    return overlay;
  }

  function createInfoBox() {
    const infoBox = document.createElement('div');
    infoBox.id = '__infinitty-info';
    infoBox.style.cssText = \`
      position: fixed;
      bottom: 20px;
      left: 50%;
      transform: translateX(-50%);
      background: rgba(0, 0, 0, 0.9);
      color: #00d9ff;
      padding: 12px 20px;
      border-radius: 8px;
      font-family: -apple-system, BlinkMacSystemFont, 'SF Mono', monospace;
      font-size: 13px;
      z-index: 999999;
      pointer-events: none;
      box-shadow: 0 4px 20px rgba(0, 0, 0, 0.4);
      border: 1px solid rgba(0, 217, 255, 0.3);
    \`;
    document.body.appendChild(infoBox);
    return infoBox;
  }

  function updateOverlay(element) {
    if (!element || !state.overlay) return;
    const rect = element.getBoundingClientRect();
    state.overlay.style.left = rect.left + 'px';
    state.overlay.style.top = rect.top + 'px';
    state.overlay.style.width = rect.width + 'px';
    state.overlay.style.height = rect.height + 'px';
    state.overlay.style.display = 'block';
  }

  function getElementInfo(element) {
    const tag = element.tagName.toLowerCase();
    const id = element.id ? '#' + element.id : '';
    const classes = element.className && typeof element.className === 'string'
      ? '.' + element.className.split(' ').filter(c => c).join('.')
      : '';
    const text = element.textContent?.trim().substring(0, 50) || '';
    return { tag, id, classes, text, selector: tag + id + classes };
  }

  function updateInfoBox(element) {
    if (!element || !state.infoBox) return;
    const info = getElementInfo(element);
    state.infoBox.innerHTML = \`
      <div style="font-weight: 600; margin-bottom: 4px;">\${info.selector}</div>
      <div style="color: #888; font-size: 11px;">
        \${info.text ? '"' + info.text + (info.text.length >= 50 ? '...' : '') + '"' : 'Click to select • ESC to cancel'}
      </div>
    \`;
  }

  function getElementContext(element) {
    const info = getElementInfo(element);
    const rect = element.getBoundingClientRect();
    const computedStyle = window.getComputedStyle(element);

    // Get outer HTML (limited to reasonable size)
    let outerHTML = element.outerHTML;
    if (outerHTML.length > 5000) {
      outerHTML = outerHTML.substring(0, 5000) + '... (truncated)';
    }

    // Get parent chain
    const parentChain = [];
    let parent = element.parentElement;
    let depth = 0;
    while (parent && depth < 5) {
      const pInfo = getElementInfo(parent);
      parentChain.push(pInfo.selector);
      parent = parent.parentElement;
      depth++;
    }

    // Get React component info if available
    let reactInfo = null;
    const fiber = element._reactFiber$ || Object.keys(element).find(k => k.startsWith('__reactFiber$'));
    if (fiber) {
      const fiberObj = typeof fiber === 'string' ? element[fiber] : fiber;
      if (fiberObj && fiberObj.type) {
        reactInfo = {
          componentName: fiberObj.type.name || fiberObj.type.displayName || 'Anonymous',
          props: fiberObj.memoizedProps ? Object.keys(fiberObj.memoizedProps) : [],
        };
      }
    }

    return {
      selector: info.selector,
      tag: info.tag,
      id: element.id || null,
      classes: Array.from(element.classList),
      text: element.textContent?.trim().substring(0, 200) || null,
      rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
      styles: {
        display: computedStyle.display,
        position: computedStyle.position,
        color: computedStyle.color,
        backgroundColor: computedStyle.backgroundColor,
        fontSize: computedStyle.fontSize,
      },
      parentChain,
      outerHTML,
      reactInfo,
      attributes: Array.from(element.attributes).reduce((acc, attr) => {
        acc[attr.name] = attr.value;
        return acc;
      }, {}),
    };
  }

  function handleMouseMove(e) {
    if (!state.active) return;
    const element = document.elementFromPoint(e.clientX, e.clientY);
    if (element && element !== state.hoveredElement &&
        element.id !== '__infinitty-overlay' &&
        element.id !== '__infinitty-info') {
      state.hoveredElement = element;
      updateOverlay(element);
      updateInfoBox(element);
    }
  }

  function handleClick(e) {
    if (!state.active || !state.hoveredElement) return;
    e.preventDefault();
    e.stopPropagation();

    state.selectedElement = state.hoveredElement;
    const context = getElementContext(state.selectedElement);

    // Send to parent window via postMessage
    window.postMessage({
      type: '__INFINITTY_ELEMENT_SELECTED',
      context: context,
    }, '*');

    // Flash effect on selection
    if (state.overlay) {
      state.overlay.style.background = 'rgba(0, 255, 100, 0.3)';
      state.overlay.style.borderColor = '#00ff64';
      setTimeout(() => {
        deactivate();
      }, 300);
    }
  }

  function handleKeyDown(e) {
    if (e.key === 'Escape') {
      deactivate();
    }
  }

  function activate() {
    if (state.active) return;
    state.active = true;
    state.overlay = createOverlay();
    state.infoBox = createInfoBox();
    document.addEventListener('mousemove', handleMouseMove, true);
    document.addEventListener('click', handleClick, true);
    document.addEventListener('keydown', handleKeyDown, true);
    document.body.style.cursor = 'crosshair';

    // Initial info
    state.infoBox.innerHTML = '<div>Hover over elements to inspect • Click to select • ESC to cancel</div>';
  }

  function deactivate() {
    if (!state.active) return;
    state.active = false;
    document.removeEventListener('mousemove', handleMouseMove, true);
    document.removeEventListener('click', handleClick, true);
    document.removeEventListener('keydown', handleKeyDown, true);
    document.body.style.cursor = '';

    if (state.overlay) {
      state.overlay.remove();
      state.overlay = null;
    }
    if (state.infoBox) {
      state.infoBox.remove();
      state.infoBox = null;
    }
    state.hoveredElement = null;
  }

  function toggle() {
    if (state.active) {
      deactivate();
    } else {
      activate();
    }
  }

  window.__infinittyElementSelector = {
    activate,
    deactivate,
    toggle,
    isActive: () => state.active,
  };

  // Start activated
  activate();
})();
`

export interface ElementContext {
  selector: string
  tag: string
  id: string | null
  classes: string[]
  text: string | null
  rect: { x: number; y: number; width: number; height: number }
  styles: Record<string, string>
  parentChain: string[]
  outerHTML: string
  reactInfo: {
    componentName: string
    props: string[]
  } | null
  attributes: Record<string, string>
}

interface UseElementSelectorOptions {
  webviewId: string
  onElementSelected?: (context: ElementContext) => void
}

export function useElementSelector({ webviewId, onElementSelected }: UseElementSelectorOptions) {
  const [isActive, setIsActive] = useState(false)
  const [lastSelected, setLastSelected] = useState<ElementContext | null>(null)

  const toggleSelector = useCallback(async () => {
    try {
      await invoke('execute_webview_script', {
        webviewId,
        script: ELEMENT_SELECTOR_SCRIPT,
      })
      setIsActive((prev) => !prev)
    } catch (err) {
      console.error('Failed to toggle element selector:', err)
    }
  }, [webviewId])

  const copyContextToClipboard = useCallback(async (context: ElementContext) => {
    const formatted = `
Element: ${context.selector}
${context.id ? `ID: ${context.id}` : ''}
${context.classes.length > 0 ? `Classes: ${context.classes.join(' ')}` : ''}
${context.text ? `Text: "${context.text}"` : ''}

Position: x=${Math.round(context.rect.x)}, y=${Math.round(context.rect.y)}, ${Math.round(context.rect.width)}x${Math.round(context.rect.height)}

Styles:
${Object.entries(context.styles).map(([k, v]) => `  ${k}: ${v}`).join('\n')}

Parent Chain:
${context.parentChain.map((p, i) => `  ${'  '.repeat(i)}${p}`).join('\n')}

${context.reactInfo ? `React Component: ${context.reactInfo.componentName}\nProps: ${context.reactInfo.props.join(', ')}` : ''}

Attributes:
${Object.entries(context.attributes).map(([k, v]) => `  ${k}="${v}"`).join('\n')}

HTML:
${context.outerHTML}
`.trim()

    try {
      await navigator.clipboard.writeText(formatted)
      setLastSelected(context)
      onElementSelected?.(context)
    } catch (err) {
      console.error('Failed to copy to clipboard:', err)
    }
  }, [onElementSelected])

  const deactivate = useCallback(async () => {
    try {
      await invoke('execute_webview_script', {
        webviewId,
        script: 'window.__infinittyElementSelector?.deactivate()',
      })
      setIsActive(false)
    } catch (err) {
      console.error('Failed to deactivate element selector:', err)
    }
  }, [webviewId])

  return {
    isActive,
    lastSelected,
    toggleSelector,
    deactivate,
    copyContextToClipboard,
  }
}
