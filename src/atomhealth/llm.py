"""Thin async client for an OpenAI-compatible chat API (local llama-server running Qwen)."""
import asyncio
import base64
import json
import re

import aiohttp

from . import config


class LLMError(Exception):
    pass


def image_part(data: bytes, mime: str = "image/jpeg") -> dict:
    """Message content part carrying an image as a base64 data URL."""
    return {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{base64.b64encode(data).decode()}"}}


def extract_json(text: str):
    """Parse a JSON object from model output, tolerating <think> blocks and ```json fences."""
    text = re.sub(r"<think>.*?</think>", "", text or "", flags=re.S).strip()
    fence = re.search(r"```(?:json)?\s*(.*?)```", text, re.S)
    if fence:
        text = fence.group(1).strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        start, end = text.find("{"), text.rfind("}")
        if start != -1 and end > start:
            try:
                return json.loads(text[start:end + 1])
            except json.JSONDecodeError:
                pass
    raise LLMError(f"model did not return valid JSON: {text[:200]!r}")


def _atom_task(messages):
    """Flatten chat messages into (task text, [image data URLs]) for an Atom agent run."""
    texts, images = [], []
    for m in messages:
        c = m.get("content")
        for part in (c if isinstance(c, list) else [{"type": "text", "text": c or ""}]):
            if part.get("type") == "image_url":
                images.append(part["image_url"]["url"])
            elif part.get("text"):
                texts.append(part["text"])
    return "\n\n".join(texts), images


class LLM:
    def __init__(self, base_url=None, model=None, api_key=None, timeout=None):
        s = config.llm_settings()
        self.base_url = (base_url or s["base_url"]).rstrip("/")
        self.model = model or s["model"]
        self.api_key = api_key or s["api_key"]
        self.timeout = timeout or s["timeout"]

    async def chat(self, messages, *, max_tokens=1500, temperature=0.2, thinking=False, retries=2, via_atom=False) -> str:
        """Return the assistant text. Thinking is off by default: it burns tokens and latency.
        Requests that carry images (or set via_atom, e.g. text-only meal corrections) go through the Atom
        AtomHealth agent when ATOM_BASE_URL is set, and fall back to the local model if Atom fails."""
        if config.atom_settings()["base_url"]:
            task, images = _atom_task(messages)
            if images or via_atom:
                try:
                    return await self._atom_run(task, images)
                except LLMError:
                    pass  # connection error, 404/422, failed/budget/stopped run: use the local model
        body = {
            "model": self.model, "messages": messages, "max_tokens": max_tokens,
            "temperature": temperature,
            "chat_template_kwargs": {"enable_thinking": thinking},
        }
        headers = {"Authorization": f"Bearer {self.api_key}"}
        last = None
        for attempt in range(retries + 1):
            try:
                async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=self.timeout)) as http:
                    async with http.post(f"{self.base_url}/chat/completions", json=body, headers=headers) as r:
                        if r.status >= 500:
                            raise LLMError(f"LLM server error {r.status}")
                        if r.status >= 400:
                            raise LLMError(f"LLM request rejected {r.status}: {(await r.text())[:200]}")
                        data = await r.json()
                content = data["choices"][0]["message"].get("content") or ""
                if not content.strip():
                    raise LLMError("empty response (token budget used up by reasoning?)")
                return content
            except (aiohttp.ClientError, asyncio.TimeoutError, LLMError, KeyError, IndexError) as e:
                last = e
                if isinstance(e, LLMError) and "rejected" in str(e):
                    break  # 4xx will not get better on retry
                await asyncio.sleep(min(2 ** attempt, 5))
        raise LLMError(f"LLM unavailable: {last}") from last

    async def chat_json(self, messages, **kw):
        return extract_json(await self.chat(messages, **kw))

    async def _atom_run(self, task: str, images) -> str:
        """Upload the image, queue an AtomHealth agent run (agent_mode=require), poll until it ends."""
        a = config.atom_settings()
        base = a["base_url"]
        headers = {"X-Atom-Client": "AtomHealth"}  # shown as the Caller on Atom's API calls page
        if a["token"]:
            headers["Authorization"] = f"Bearer {a['token']}"
        try:
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=a["timeout"]), headers=headers) as http:
                upload_ids = []
                for n, data_url in enumerate(images):
                    async with http.post(f"{base}/api/uploads", json={"data_url": data_url, "name": f"meal{n}.jpg"}) as r:
                        if r.status >= 300:
                            raise LLMError(f"Atom upload failed {r.status}: {(await r.text())[:200]}")
                        upload_ids.append((await r.json())["id"])
                body = {"agent": a["agent"], "task": task, "images": upload_ids, "agent_mode": "require"}
                async with http.post(f"{base}/api/agents/run", json=body) as r:
                    if r.status >= 300:
                        raise LLMError(f"Atom run rejected {r.status}: {(await r.text())[:200]}")
                    run_id = (await r.json()).get("run_id")
                if not run_id:
                    raise LLMError("Atom returned no run_id")
                while True:
                    async with http.get(f"{base}/api/runs/{run_id}") as r:
                        if r.status >= 300:
                            raise LLMError(f"Atom run lookup failed {r.status}")
                        run = (await r.json()).get("run") or {}
                    st = run.get("status")
                    if st not in ("queued", "running"):
                        break
                    await asyncio.sleep(a["poll"])
        except (aiohttp.ClientError, asyncio.TimeoutError, KeyError, ValueError) as e:
            raise LLMError(f"Atom unavailable: {e}") from e
        if st != "done":
            raise LLMError(f"Atom run {st}: {run.get('error')}")
        res = run.get("result")
        return res if isinstance(res, str) else json.dumps(res)

    async def analyze_image(self, prompt: str, image: bytes, mime="image/jpeg", system=None, **kw):
        """Send one image + prompt; return parsed JSON."""
        msgs = ([{"role": "system", "content": system}] if system else []) + [
            {"role": "user", "content": [{"type": "text", "text": prompt}, image_part(image, mime)]}]
        return await self.chat_json(msgs, **kw)
