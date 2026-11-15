import { Router } from "express";
import type { Request, Response } from "express";
import type { SkillLoader } from "../skill-loader.js";

// GET  /skills        – loaded skills (token required)
// POST /skills/reload – reload skills and update the system prompt

export function createSkillsRouter(skillLoader: SkillLoader, onReload: () => void): Router {
  const router = Router();

  router.get("/", (_req: Request, res: Response): void => {
    res.json({ skills: skillLoader.getSkillList(), count: skillLoader.count });
  });

  router.post("/reload", (_req: Request, res: Response): void => {
    skillLoader.reload();
    onReload();
    res.json({
      message: "Skills reloaded",
      skills: skillLoader.getSkillList(),
      count: skillLoader.count,
    });
  });

  return router;
}
