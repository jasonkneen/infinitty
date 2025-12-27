import { tool } from 'ai';
import { z } from 'zod';

// Helper to convert JSON Schema to Zod
function jsonSchemaToZod(schema: any): z.ZodTypeAny {
  if (!schema) return z.any();
  
  // Handle 'anyOf' / 'oneOf' by taking the first one or defaulting to any (simplification)
  if (schema.anyOf || schema.oneOf) {
    return z.any().describe(schema.description || '');
  }

  switch (schema.type) {
    case 'string':
      return z.string().describe(schema.description || '');
    case 'number':
    case 'integer':
      return z.number().describe(schema.description || '');
    case 'boolean':
      return z.boolean().describe(schema.description || '');
    case 'object':
      if (schema.properties) {
        const required = new Set(Array.isArray(schema.required) ? schema.required : []);
        const shape: Record<string, z.ZodTypeAny> = {};
        
        for (const [key, value] of Object.entries(schema.properties)) {
          let zodSchema = jsonSchemaToZod(value);
          if (!required.has(key)) {
            zodSchema = zodSchema.optional();
          }
          shape[key] = zodSchema;
        }
        // Zod v4 requires the classic `object(shape, params?)` signature.
        // Providing an explicit params object avoids TS overload issues in some setups.
        return z.object(shape, {}).describe(schema.description || '');
      }
      // Zod v4 record() requires both key and value schemas.
      return z.record(z.string(), z.any()).describe(schema.description || '');
    case 'array':
      if (schema.items) {
        return z.array(jsonSchemaToZod(schema.items)).describe(schema.description || '');
      }
      return z.array(z.any()).describe(schema.description || '');
    default:
      return z.any().describe(schema.description || '');
  }
}

export function getAIToolsFromMCP(mcpManager: any) {
  if (!mcpManager) return {};

  const allTools = mcpManager.getAllTools();
  const aiTools: Record<string, any> = {};

  for (const { tool: mcpTool, serverId } of allTools) {
    aiTools[mcpTool.name] = tool({
      description: mcpTool.description,
      inputSchema: jsonSchemaToZod(mcpTool.inputSchema),
      execute: async (input: any) => {
        try {
          const result = await mcpManager.callTool(serverId, mcpTool.name, input);
          // MCP tools return { content: [...] } or similar.
          // AI SDK expects a result that can be serialized.
          // If result is an object with content, we might want to return just the content or the whole thing.
          // Let's return the whole result for now.
          if (typeof result === 'string') return result;
          try {
            // Prefer returning the raw object when possible (serializable JSON).
            return result;
          } catch {
            return JSON.stringify(result);
          }
        } catch (error: any) {
          return `Error executing tool ${mcpTool.name}: ${error.message}`;
        }
      },
    });
  }

  return aiTools;
}
