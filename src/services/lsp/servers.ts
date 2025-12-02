/**
 * LSP Server Definitions
 * Configuration for supported language servers
 */

export interface ServerDefinition {
  id: string
  name: string
  extensions: string[]
  rootPatterns: string[]
  excludePatterns?: string[]
  installCommand?: string
  installType: 'npm' | 'cargo' | 'go' | 'github' | 'system'
  binaryName: string
  args: string[]
}

/**
 * Supported language servers
 */
export const SERVERS: Record<string, ServerDefinition> = {
  'typescript-language-server': {
    id: 'typescript-language-server',
    name: 'TypeScript',
    extensions: ['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs'],
    rootPatterns: ['package.json', 'tsconfig.json', 'jsconfig.json'],
    installCommand: 'npm install -g typescript-language-server typescript',
    installType: 'npm',
    binaryName: 'typescript-language-server',
    args: ['--stdio'],
  },
  'pyright-langserver': {
    id: 'pyright-langserver',
    name: 'Python (Pyright)',
    extensions: ['.py', '.pyi'],
    rootPatterns: ['pyproject.toml', 'setup.py', 'requirements.txt', 'setup.cfg'],
    installCommand: 'npm install -g pyright',
    installType: 'npm',
    binaryName: 'pyright-langserver',
    args: ['--stdio'],
  },
  'gopls': {
    id: 'gopls',
    name: 'Go',
    extensions: ['.go'],
    rootPatterns: ['go.mod', 'go.sum'],
    installCommand: 'go install golang.org/x/tools/gopls@latest',
    installType: 'go',
    binaryName: 'gopls',
    args: ['serve'],
  },
  'rust-analyzer': {
    id: 'rust-analyzer',
    name: 'Rust',
    extensions: ['.rs'],
    rootPatterns: ['Cargo.toml'],
    installType: 'github',
    binaryName: 'rust-analyzer',
    args: [],
  },
  'vscode-json-language-server': {
    id: 'vscode-json-language-server',
    name: 'JSON',
    extensions: ['.json', '.jsonc'],
    rootPatterns: ['package.json'],
    installCommand: 'npm install -g vscode-langservers-extracted',
    installType: 'npm',
    binaryName: 'vscode-json-language-server',
    args: ['--stdio'],
  },
  'vscode-css-language-server': {
    id: 'vscode-css-language-server',
    name: 'CSS/SCSS/Less',
    extensions: ['.css', '.scss', '.sass', '.less'],
    rootPatterns: ['package.json'],
    installCommand: 'npm install -g vscode-langservers-extracted',
    installType: 'npm',
    binaryName: 'vscode-css-language-server',
    args: ['--stdio'],
  },
  'vscode-html-language-server': {
    id: 'vscode-html-language-server',
    name: 'HTML',
    extensions: ['.html', '.htm'],
    rootPatterns: ['package.json', 'index.html'],
    installCommand: 'npm install -g vscode-langservers-extracted',
    installType: 'npm',
    binaryName: 'vscode-html-language-server',
    args: ['--stdio'],
  },
  'yaml-language-server': {
    id: 'yaml-language-server',
    name: 'YAML',
    extensions: ['.yaml', '.yml'],
    rootPatterns: ['package.json'],
    installCommand: 'npm install -g yaml-language-server',
    installType: 'npm',
    binaryName: 'yaml-language-server',
    args: ['--stdio'],
  },
  'tailwindcss-language-server': {
    id: 'tailwindcss-language-server',
    name: 'Tailwind CSS',
    extensions: ['.html', '.jsx', '.tsx', '.vue', '.svelte'],
    rootPatterns: ['tailwind.config.js', 'tailwind.config.ts', 'tailwind.config.cjs', 'tailwind.config.mjs'],
    installCommand: 'npm install -g @tailwindcss/language-server',
    installType: 'npm',
    binaryName: 'tailwindcss-language-server',
    args: ['--stdio'],
  },
  'vscode-eslint-language-server': {
    id: 'vscode-eslint-language-server',
    name: 'ESLint',
    extensions: ['.js', '.jsx', '.ts', '.tsx', '.mjs', '.cjs'],
    rootPatterns: ['.eslintrc', '.eslintrc.js', '.eslintrc.json', '.eslintrc.yaml', '.eslintrc.yml', 'eslint.config.js', 'eslint.config.mjs'],
    installCommand: 'npm install -g vscode-langservers-extracted',
    installType: 'npm',
    binaryName: 'vscode-eslint-language-server',
    args: ['--stdio'],
  },
}

/**
 * Get servers for a file extension
 */
export function getServersForExtension(ext: string): ServerDefinition[] {
  return Object.values(SERVERS).filter(server =>
    server.extensions.includes(ext.toLowerCase())
  )
}

/**
 * Get all servers
 */
export function getAllServers(): ServerDefinition[] {
  return Object.values(SERVERS)
}

/**
 * Get a specific server by ID
 */
export function getServer(id: string): ServerDefinition | undefined {
  return SERVERS[id]
}

/**
 * Language ID mappings for LSP
 */
export const LANGUAGE_EXTENSIONS: Record<string, string> = {
  '.ts': 'typescript',
  '.tsx': 'typescriptreact',
  '.js': 'javascript',
  '.jsx': 'javascriptreact',
  '.mjs': 'javascript',
  '.cjs': 'javascript',
  '.py': 'python',
  '.pyi': 'python',
  '.go': 'go',
  '.rs': 'rust',
  '.json': 'json',
  '.jsonc': 'jsonc',
  '.css': 'css',
  '.scss': 'scss',
  '.sass': 'sass',
  '.less': 'less',
  '.html': 'html',
  '.htm': 'html',
  '.yaml': 'yaml',
  '.yml': 'yaml',
  '.md': 'markdown',
  '.mdx': 'mdx',
  '.vue': 'vue',
  '.svelte': 'svelte',
  '.astro': 'astro',
  '.php': 'php',
  '.rb': 'ruby',
  '.java': 'java',
  '.kt': 'kotlin',
  '.swift': 'swift',
  '.c': 'c',
  '.cpp': 'cpp',
  '.cc': 'cpp',
  '.h': 'c',
  '.hpp': 'cpp',
  '.cs': 'csharp',
  '.sh': 'shellscript',
  '.bash': 'shellscript',
  '.zsh': 'shellscript',
  '.fish': 'fish',
  '.sql': 'sql',
  '.graphql': 'graphql',
  '.gql': 'graphql',
  '.prisma': 'prisma',
  '.dockerfile': 'dockerfile',
  '.toml': 'toml',
  '.ini': 'ini',
  '.xml': 'xml',
  '.svg': 'xml',
}

/**
 * Get language ID for a file extension
 */
export function getLanguageId(ext: string): string {
  return LANGUAGE_EXTENSIONS[ext.toLowerCase()] || 'plaintext'
}
