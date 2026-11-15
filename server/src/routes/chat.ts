import { Router } from "express";
import type { Request, Response } from "express";
import { buildUserMessage, describeChatError } from "../claude-client.js";
import type { ClaudeClient } from "../claude-client.js";
import { c } from "../console-theme.js";
import type { ConversationStore } from "../conversation.js";
import { HTTP_BAD_REQUEST, sendError } from "../http.js";
import type { RequestQueue } from "../middleware.js";
import type { ChatResponse } from "../types.js";
import { validateChatRequest } from "../validation.js";

// POST /chat – contract with the iOS app:
//   Body:    { text, images?: string[] (Base64), conversation_id? }
//   Response: { text, tool_calls: [{ name, result }], conversation_id }

export function createChatRouter(
  claudeClient: ClaudeClient,
  conversations: ConversationStore,
  requestQueue: RequestQueue
): Router {
  const router = Router();

  router.post("/", async (req: Request, res: Response): Promise<void> => {
    const validation = validateChatRequest(req.body);
    if (!validation.ok) {
      sendError(res, HTTP_BAD_REQUEST, validation.error);
      return;
    }

    const { text, images, conversationId } = validation.value;
    const id = conversations.resolveId(conversationId);

    try {
      // Read the history only at execution time - so a waiting request
      // also sees the turn that ran right before it in the same conversation.
      const result = await requestQueue.enqueue(() =>
        claudeClient.chat(conversations.getHistory(id), text, images)
      );

      if (!result.refused) {
        conversations.appendTurn(id, buildUserMessage(text, images), {
          role: "assistant",
          content: result.responseText,
        });
      }

      const response: ChatResponse = {
        text: result.responseText,
        tool_calls: [...result.toolCalls],
        conversation_id: id,
      };
      res.json(response);
    } catch (err) {
      // Details (incl. SDK error text) only go to the log, the client only gets a neutral message
      console.error(c.label("[Chat]") + c.error(" Request failed:"), err);
      const { status, message } = describeChatError(err);
      sendError(res, status, message);
    }
  });

  return router;
}
