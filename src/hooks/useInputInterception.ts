import { useCallback } from 'react'

// Common shell command prefixes and patterns
const SHELL_COMMAND_PATTERNS = [
  // Common commands
  /^(ls|cd|pwd|cat|echo|grep|find|mkdir|rm|cp|mv|touch|chmod|chown|sudo|apt|brew|npm|yarn|pnpm|git|docker|kubectl|python|node|ruby|go|cargo|make|cmake|gcc|clang|vim|nano|code|open|which|whereis|man|help|exit|clear|history|alias|export|source|curl|wget|ssh|scp|rsync|tar|zip|unzip|gzip|gunzip|head|tail|less|more|wc|sort|uniq|diff|patch|sed|awk|tr|cut|paste|xargs|tee|env|set|unset|read|eval|exec|kill|ps|top|htop|fg|bg|jobs|nohup|screen|tmux|ping|traceroute|netstat|ifconfig|ip|dig|nslookup|host|nvim|emacs|bat|rg|fd|exa|z|j|fzf|ag|ack|jq|yq|terraform|ansible|helm|aws|gcloud|az|vercel|netlify|heroku|fly|railway|deno|bun|npx|bunx|pipx|cargo|rustc|rustup|bundle|gem|pip|pip3|poetry|pdm|uv|composer|php|java|javac|mvn|gradle|dotnet|swift|xcodebuild|flutter|dart|zig|clj|lein|mix|elixir|iex|erl|ghc|cabal|stack|scala|sbt|kotlin|kotlinc|clojure|julia|r|Rscript|lua|perl|tcl|bash|zsh|fish|sh|csh|ksh|dash|pwsh|powershell)\b/i,
  // Commands with flags
  /^[a-z][\w-]*\s+-{1,2}[a-z]/i,
  // Paths
  /^[.~\/]/,
  // Pipes and redirects
  /[|><]/,
  // Variable assignments
  /^[A-Z_][A-Z0-9_]*=/,
  // Command substitution
  /\$\(|\`/,
  // Shebang
  /^#!/,
  // Chained commands
  /&&|\|\|/,
  // Semicolon separated commands
  /;\s*[a-z]/i,
]

// Natural language indicators
const NATURAL_LANGUAGE_PATTERNS = [
  // Questions
  /^(what|how|why|when|where|who|which|can|could|would|should|is|are|do|does|did|will|have|has|explain|describe|show|tell|help|please|i want|i need|i'd like|create|make|build|write|generate|fix|debug|find|search|look for)\b/i,
  // Polite requests
  /^(please|could you|would you|can you|i want to|i need to|i'd like to|help me)\b/i,
  // Sentences with common verbs
  /\b(the|a|an|this|that|these|those|my|your|our|their|it's|its|there|here)\b/i,
]

// Words that strongly indicate natural language
const NATURAL_LANGUAGE_WORDS = [
  'please', 'thanks', 'thank', 'help', 'explain', 'describe', 'why', 'because',
  'want', 'need', 'would', 'could', 'should', 'might', 'maybe', 'probably',
  'think', 'know', 'understand', 'mean', 'work', 'working', 'broken', 'error',
  'wrong', 'right', 'correct', 'incorrect', 'issue', 'problem', 'solution',
]

export interface InputInterceptionResult {
  isNaturalLanguage: boolean
  confidence: number // 0-1
  suggestion?: string
}

export function detectNaturalLanguage(input: string): InputInterceptionResult {
  const trimmed = input.trim()

  // Empty or very short input
  if (!trimmed || trimmed.length < 3) {
    return { isNaturalLanguage: false, confidence: 0 }
  }

  // Check if it looks like a shell command
  for (const pattern of SHELL_COMMAND_PATTERNS) {
    if (pattern.test(trimmed)) {
      return { isNaturalLanguage: false, confidence: 0 }
    }
  }

  let confidence = 0
  const words = trimmed.toLowerCase().split(/\s+/)

  // Check for natural language patterns
  for (const pattern of NATURAL_LANGUAGE_PATTERNS) {
    if (pattern.test(trimmed)) {
      confidence += 0.3
    }
  }

  // Check for natural language words
  const nlWordCount = words.filter(word =>
    NATURAL_LANGUAGE_WORDS.includes(word.replace(/[^a-z]/g, ''))
  ).length
  confidence += Math.min(nlWordCount * 0.15, 0.4)

  // Multiple words suggest natural language
  if (words.length >= 3) {
    confidence += 0.1
  }
  if (words.length >= 5) {
    confidence += 0.1
  }

  // Ends with question mark
  if (trimmed.endsWith('?')) {
    confidence += 0.2
  }

  // Contains spaces (commands often don't have many)
  if (trimmed.includes(' ') && words.length > 2) {
    confidence += 0.1
  }

  // Doesn't start with lowercase single word that could be a command
  if (!/^[a-z][\w-]*$/.test(words[0])) {
    confidence += 0.1
  }

  // Cap confidence at 1
  confidence = Math.min(confidence, 1)

  const isNaturalLanguage = confidence >= 0.5

  return {
    isNaturalLanguage,
    confidence,
    suggestion: isNaturalLanguage
      ? 'This looks like a question. Press Tab to send to AI instead.'
      : undefined,
  }
}

export interface CLIDetectionResult {
  isCLICommand: boolean
  confidence: number
  forceTerminal: boolean  // ! prefix
  forceAI: boolean        // ? prefix
  cleanedInput: string    // Input without the prefix
}

export function detectCLICommand(input: string): CLIDetectionResult {
  const trimmed = input.trim()

  // Check for force prefixes
  if (trimmed.startsWith('!')) {
    return {
      isCLICommand: true,
      confidence: 1,
      forceTerminal: true,
      forceAI: false,
      cleanedInput: trimmed.slice(1).trim(),
    }
  }

  if (trimmed.startsWith('?')) {
    return {
      isCLICommand: false,
      confidence: 0,
      forceTerminal: false,
      forceAI: true,
      cleanedInput: trimmed.slice(1).trim(),
    }
  }

  // Empty or very short input
  if (!trimmed || trimmed.length < 2) {
    return { isCLICommand: false, confidence: 0, forceTerminal: false, forceAI: false, cleanedInput: trimmed }
  }

  let confidence = 0

  // Check shell command patterns
  for (const pattern of SHELL_COMMAND_PATTERNS) {
    if (pattern.test(trimmed)) {
      confidence += 0.5
      break
    }
  }

  // Single word that matches a command exactly
  const firstWord = trimmed.split(/\s+/)[0].toLowerCase()
  const commonCommands = ['ls', 'cd', 'pwd', 'cat', 'echo', 'grep', 'git', 'npm', 'yarn', 'pnpm', 'docker', 'python', 'node', 'go', 'cargo', 'make', 'vim', 'code', 'curl', 'wget', 'ssh', 'mkdir', 'rm', 'cp', 'mv', 'touch', 'chmod', 'sudo', 'brew', 'apt', 'pip', 'bundle', 'gem', 'flutter', 'dart', 'bun', 'deno', 'npx', 'nvim', 'bat', 'rg', 'fd', 'terraform', 'kubectl', 'helm', 'aws', 'gcloud', 'vercel']
  if (commonCommands.includes(firstWord)) {
    confidence += 0.4
  }

  // Has flags (-x or --xxx)
  if (/\s-{1,2}[a-z]/i.test(trimmed)) {
    confidence += 0.2
  }

  // Short input without spaces likely a command
  if (!trimmed.includes(' ') && /^[a-z][\w-]*$/i.test(trimmed)) {
    confidence += 0.2
  }

  // Cap at 1
  confidence = Math.min(confidence, 1)

  return {
    isCLICommand: confidence >= 0.5,
    confidence,
    forceTerminal: false,
    forceAI: false,
    cleanedInput: trimmed,
  }
}

export function useInputInterception() {
  const checkInput = useCallback((input: string): InputInterceptionResult => {
    return detectNaturalLanguage(input)
  }, [])

  const checkCLI = useCallback((input: string): CLIDetectionResult => {
    return detectCLICommand(input)
  }, [])

  return { checkInput, detectNaturalLanguage, checkCLI, detectCLICommand }
}
