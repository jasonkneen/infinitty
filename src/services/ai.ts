import { createAnthropic } from '@ai-sdk/anthropic';
import { createOpenAI } from '@ai-sdk/openai';
import { streamText, type LanguageModel } from 'ai';
import { getAIToolsFromMCP } from '../lib/ai/mcp-adapter';
import { getShellEnv } from '../lib/shellEnv';
import { z } from 'zod';

// NOTE: `claude-code` is a local-auth provider backed by `claude-agent-sdk`.
// It intentionally does NOT require `ANTHROPIC_API_KEY`.
export type AIProvider = 'anthropic' | 'openai' | 'claude-code';

export type ThinkingLevel = 'none' | 'low' | 'medium' | 'high';

export const THINKING_BUDGETS: Record<ThinkingLevel, number> = {
  none: 0,
  low: 5000,
  medium: 20000,
  high: 50000,
};

export function getThinkingLevelLabel(level: ThinkingLevel): string {
  switch (level) {
    case 'none': return 'Off'
    case 'low': return 'Low (~5k tokens)'
    case 'medium': return 'Medium (~20k tokens)'
    case 'high': return 'High (~50k tokens)'
  }
}

export interface StreamChatOptions {
  modelId: string;
  provider: AIProvider;
  messages: any[]; // CoreMessage[]
  thinking?: {
    type: 'enabled' | 'disabled';
    budget?: number;
  };
  cwd?: string;
}

type InternalStreamPart =
  | { type: 'text-delta'; text: string }
  | { type: 'reasoning-start' }
  | { type: 'reasoning-delta'; text: string }
  | { type: 'tool-call'; toolCallId: string; toolName: string; input: unknown }
  | { type: 'tool-result'; toolCallId: string; toolName?: string; output: unknown }
  | { type: 'error'; error: string };

function getMcpManager(): any | null {
  return (globalThis as any).__infinittyMcpManager ?? null;
}

function isTauriRuntime(): boolean {
  // Tauri v1 exposes `window.__TAURI__`; Tauri v2 commonly exposes `window.__TAURI_INTERNALS__`.
  // Check both so we reliably detect Tauri across versions.
  if (typeof window === 'undefined') return false;
  const w = window as any;
  return Boolean(w.__TAURI__ || w.__TAURI_INTERNALS__);
}

function requireNonEmptyEnvVar(env: Record<string, string | undefined>, key: string): string {
  const value = env[key];
  if (!value || !value.trim()) {
    // IMPORTANT: throw a plain Error so the UI shows an actionable message.
    // If a key exists but is invalid, the provider will still throw AI_APICallError as before.
    throw new Error(`Missing ${key}. Set it in your environment (or .env) and restart.`);
  }
  return value;
}

function jsonSchemaToZod(schema: any): z.ZodTypeAny {
  if (!schema) return z.any();
  if (schema.anyOf || schema.oneOf) return z.any().describe(schema.description || '');

  switch (schema.type) {
    case 'string':
      return z.string().describe(schema.description || '');
    case 'number':
    case 'integer':
      return z.number().describe(schema.description || '');
    case 'boolean':
      return z.boolean().describe(schema.description || '');
    case 'array':
      return z.array(jsonSchemaToZod(schema.items)).describe(schema.description || '');
    case 'object': {
      const shape: Record<string, z.ZodTypeAny> = {};
      const required = new Set(Array.isArray(schema.required) ? schema.required : []);
      for (const [key, value] of Object.entries(schema.properties ?? {})) {
        const child = jsonSchemaToZod(value);
        shape[key] = required.has(key) ? child : child.optional();
      }
      return z.object(shape, {}).describe(schema.description || '');
    }
    default:
      return z.any().describe(schema.description || '');
  }
}

function jsonSchemaToZodRawShape(schema: any): z.ZodRawShape {
  // Claude Agent SDK tool definitions require a ZodRawShape.
  // MCP tool input schemas are typically `type: 'object'`.
  const raw: Record<string, z.ZodTypeAny> = {};
  if (!schema || schema.type !== 'object' || !schema.properties) return raw as any;

  const required = new Set(Array.isArray(schema.required) ? schema.required : []);
  for (const [key, value] of Object.entries(schema.properties)) {
    const child = jsonSchemaToZod(value);
    raw[key] = required.has(key) ? child : child.optional();
  }
  return raw as any;
}

function coreMessagesToTranscript(messages: any[]): string {
  // Minimal conversion from AI SDK "CoreMessage[]" shape into a text transcript.
  // This is used only for `claude-agent-sdk` which takes a plain prompt.
  const chunks: string[] = [];
  for (const msg of messages) {
    const role = msg?.role;
    const content = msg?.content;

    const text = (() => {
      if (typeof content === 'string') return content;
      if (Array.isArray(content)) {
        return content
          .map((p: any) => {
            if (p?.type === 'text') return p.text;
            if (p?.type === 'tool-result') {
              const out = p.output ?? '';
              return `Tool result (${p.toolName || p.toolCallId}): ${typeof out === 'string' ? out : JSON.stringify(out)}`;
            }
            if (p?.type === 'tool-call') {
              return `Tool call (${p.toolName || p.toolCallId}): ${JSON.stringify(p.input ?? {})}`;
            }
            return '';
          })
          .filter(Boolean)
          .join('');
      }
      return '';
    })();

    if (!text.trim()) continue;
    if (role === 'user') chunks.push(`User: ${text}`);
    else if (role === 'assistant') chunks.push(`Assistant: ${text}`);
    else if (role === 'tool') chunks.push(`Tool: ${text}`);
    else chunks.push(`${String(role)}: ${text}`);
  }
  return chunks.join('\n\n');
}

async function* streamWithClaudeAgentSdk(options: StreamChatOptions): AsyncGenerator<InternalStreamPart, void> {
  const {
    query,
    createSdkMcpServer,
    tool: sdkTool,
  } = await import('claude-agent-sdk');

  const mcpManager = getMcpManager();
  const env = await getShellEnv();

  // Build an in-process MCP server backed by the app's MCP manager.
  // This allows Claude Code to call the same tools the AI SDK path exposes.
  const sdkTools: any[] = [];
  if (mcpManager) {
    for (const { tool: mcpTool, serverId } of mcpManager.getAllTools()) {
      sdkTools.push(
        sdkTool(
          mcpTool.name,
          mcpTool.description,
          jsonSchemaToZodRawShape(mcpTool.inputSchema),
          async (input: any) => {
            const result = await mcpManager.callTool(serverId, mcpTool.name, input);

            // Normalize result to MCP CallToolResult shape if needed.
            if (result && typeof result === 'object' && 'content' in (result as any)) {
              return result as any;
            }
            const asText = typeof result === 'string' ? result : JSON.stringify(result);
            return { content: [{ type: 'text', text: asText }] } as any;
          }
        )
      );
    }
  }

  const sdkMcpServer = sdkTools.length
    ? createSdkMcpServer({ name: 'infinitty-mcp', version: '0.1.0', tools: sdkTools })
    : undefined;

  const system = `You are an expert coding assistant.\nCurrent working directory: ${options.cwd || 'unknown'}\n`;
  const prompt = coreMessagesToTranscript(options.messages);

  // `claude-agent-sdk` takes a plain prompt (not CoreMessage[]). We provide a simple transcript.
  const q = query({
    prompt,
    options: {
      cwd: options.cwd,
      env,
      model: options.modelId,
      systemPrompt: system,
      includePartialMessages: true,
      maxThinkingTokens: options.thinking?.type === 'enabled' ? options.thinking.budget : undefined,
      tools: { type: 'preset', preset: 'claude_code' },
      mcpServers: sdkMcpServer ? { 'infinitty-mcp': sdkMcpServer } : undefined,
      // Claude Code reads its auth from local config; we do not supply ANTHROPIC_API_KEY.
      settingSources: ['user', 'project', 'local'],
    },
  });

  // Track tool input JSON streamed as deltas so we can emit a single tool-call part.
  // Anthropic streaming events reference blocks by `index`, so we keep an index->toolUseId map.
  const toolUseState = new Map<string, { name: string; json: string }>();
  const toolUseIdByIndex = new Map<number, string>();

  for await (const msg of q as AsyncIterable<any>) {
    if (!msg || typeof msg !== 'object') continue;

    // Claude Agent SDK exposes Anthropic stream events when includePartialMessages=true.
    if (msg.type === 'stream_event') {
      const ev = msg.event as any;

      if (ev?.type === 'content_block_start') {
        const block = ev.content_block;
        if (block?.type === 'thinking') {
          yield { type: 'reasoning-start' };
        }
        if (block?.type === 'tool_use' && block?.id && block?.name) {
          toolUseState.set(block.id, { name: block.name, json: '' });
          if (typeof ev.index === 'number') {
            toolUseIdByIndex.set(ev.index, block.id);
          }
        }
      } else if (ev?.type === 'content_block_delta') {
        const delta = ev.delta;
        if (delta?.type === 'text_delta' && typeof delta.text === 'string') {
          yield { type: 'text-delta', text: delta.text };
        } else if (delta?.type === 'thinking_delta' && typeof delta.thinking === 'string') {
          yield { type: 'reasoning-delta', text: delta.thinking };
        } else if (delta?.type === 'input_json_delta' && typeof delta.partial_json === 'string') {
          // Tool input JSON is streamed in pieces.
          const toolUseId =
            (typeof ev.index === 'number' ? toolUseIdByIndex.get(ev.index) : undefined) ||
            delta?.tool_use_id;

          const current = toolUseId ? toolUseState.get(String(toolUseId)) : undefined;
          if (current) current.json += delta.partial_json;
        }
      } else if (ev?.type === 'content_block_stop') {
        // Tool uses are finalized at block stop; emit tool-call once we have full JSON.
        const toolUseId = typeof ev.index === 'number' ? toolUseIdByIndex.get(ev.index) : undefined;
        if (toolUseId) {
          const state = toolUseState.get(toolUseId);
          if (state) {
            let parsed: unknown = {};
            try {
              parsed = state.json ? JSON.parse(state.json) : {};
            } catch {
              parsed = state.json;
            }
            yield { type: 'tool-call', toolCallId: toolUseId, toolName: state.name, input: parsed };
            toolUseState.delete(toolUseId);
          }
          toolUseIdByIndex.delete(ev.index);
        }
      }
      continue;
    }

    // Tool results often surface as synthetic user messages containing tool_result blocks.
    if (msg.type === 'user') {
      const content = msg.message?.content;
      if (Array.isArray(content)) {
        for (const block of content) {
          if (block?.type === 'tool_result' && block?.tool_use_id) {
            const toolUseId = String(block.tool_use_id);
            const output = (() => {
              const c = block.content;
              if (typeof c === 'string') return c;
              if (Array.isArray(c)) {
                return c
                  .map((p: any) => (p?.type === 'text' ? p.text : typeof p === 'string' ? p : ''))
                  .filter(Boolean)
                  .join('');
              }
              return c ?? '';
            })();

            yield { type: 'tool-result', toolCallId: toolUseId, output };
          }
        }
      }
      continue;
    }

    if (msg.type === 'auth_status' && msg.error) {
      yield { type: 'error', error: String(msg.error) };
      continue;
    }

    if (msg.type === 'result' && msg.subtype && msg.is_error) {
      const errors = Array.isArray(msg.errors) ? msg.errors.join('\n') : msg.result;
      yield { type: 'error', error: String(errors || 'Claude Agent SDK error') };
      continue;
    }
  }
}

export async function streamChat(options: StreamChatOptions) {
  const debug = import.meta.env.DEV

  try {
    const { modelId, provider, messages, thinking } = options;

    // AI SDK v6 uses a `fetch` implementation for provider HTTP calls.
    // In Tauri, WebView `globalThis.fetch` can hit CORS preflight failures.
    // Use tauri-plugin-http fetch when running under Tauri, otherwise fall back.
    const isTauriEnv = isTauriRuntime();
    let fetchImplementationLabel: 'tauri plugin fetch' | 'web fetch' | 'tauri plugin import failed' = 'web fetch';
    let providerFetch: typeof globalThis.fetch = globalThis.fetch;

    if (isTauriEnv) {
      try {
        // Dynamic import so web builds don't hard-depend on the Tauri plugin at module eval time.
        const mod = await import('@tauri-apps/plugin-http');
        providerFetch = (mod.fetch as any) ?? globalThis.fetch;
        fetchImplementationLabel = 'tauri plugin fetch';
      } catch (error) {
        fetchImplementationLabel = 'tauri plugin import failed';
        providerFetch = globalThis.fetch;
        if (debug) {
          console.error('[ai.streamChat] failed to import @tauri-apps/plugin-http; falling back to web fetch', error);
        }
      }
    }

    if (debug) console.log(`[ai.streamChat] fetch implementation: ${fetchImplementationLabel}`)

    // `claude-code` uses local Claude Code auth via `claude-agent-sdk`.
    // It does NOT use the Anthropic HTTP API and does not require ANTHROPIC_API_KEY.
    if (provider === 'claude-code') {
      const fullStream = streamWithClaudeAgentSdk(options);
      return { fullStream } as any;
    }

    // Load environment variables to get API keys.
    // NOTE: we intentionally read the full shell env here (not the PATH-only subset)
    // so secrets like OPENAI_API_KEY / ANTHROPIC_API_KEY are available in Tauri.
    const env = await getShellEnv();

    let model: LanguageModel;

    if (provider === 'anthropic') {
      const apiKey = requireNonEmptyEnvVar(env, 'ANTHROPIC_API_KEY');
      const anthropic = createAnthropic({
        apiKey,
        fetch: providerFetch,
      });
      model = anthropic(modelId);
    } else {
      const apiKey = requireNonEmptyEnvVar(env, 'OPENAI_API_KEY');
      const openai = createOpenAI({
        apiKey,
        fetch: providerFetch,
      });
      model = openai(modelId);
    }

    const mcpManager = getMcpManager();
    const tools = getAIToolsFromMCP(mcpManager);

    const system = `You are an expert coding assistant.
Current working directory: ${options.cwd || 'unknown'}
`;

    const result = streamText({
      model,
      messages,
      system,
      tools,
      maxSteps: 10,
      providerOptions: {
        anthropic: {
          thinking: thinking?.type === 'enabled' ? {
            type: 'enabled',
            budgetTokens: thinking.budget || 1024
          } : undefined
        }
      }
    } as any);

    return result;
  } catch (error) {
    if (debug) {
      const message = error instanceof Error ? error.message : String(error)
      const stack = error instanceof Error ? error.stack : undefined
      console.error('[ai.streamChat] exception:', { message, stack })
    }
    // IMPORTANT: bubble errors so the caller can decide whether to clear the prompt.
    throw error
  }
}
