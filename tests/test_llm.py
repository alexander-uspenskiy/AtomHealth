import asyncio

import pytest
from aiohttp import web
from aiohttp.test_utils import TestServer

from atomhealth import config, llm


def test_extract_json_variants():
    assert llm.extract_json('{"a": 1}') == {"a": 1}
    assert llm.extract_json('```json\n{"a": 2}\n```') == {"a": 2}
    assert llm.extract_json('<think>hmm {x}</think>\nSure: {"a": 3} done') == {"a": 3}
    with pytest.raises(llm.LLMError):
        llm.extract_json("no json here")


def test_image_part_is_data_url():
    p = llm.image_part(b"\xff\xd8abc")
    assert p["type"] == "image_url" and p["image_url"]["url"].startswith("data:image/jpeg;base64,")


def test_dotenv_does_not_override(tmp_path, monkeypatch):
    f = tmp_path / ".env"
    f.write_text("# c\nFOO_X=1\nBAR_X='two'\nKEEP_X=new\n")
    monkeypatch.setenv("KEEP_X", "old")
    monkeypatch.delenv("FOO_X", raising=False)
    monkeypatch.delenv("BAR_X", raising=False)
    config.load_dotenv(f)
    import os
    assert os.environ["FOO_X"] == "1" and os.environ["BAR_X"] == "two" and os.environ["KEEP_X"] == "old"
    for k in ("FOO_X", "BAR_X"):
        os.environ.pop(k, None)


def _run_with_server(handler, coro_fn):
    async def go():
        app = web.Application()
        app.router.add_post("/v1/chat/completions", handler)
        async with TestServer(app) as srv:
            client = llm.LLM(base_url=str(srv.make_url("/v1")), model="m", api_key="k", timeout=5)
            return await coro_fn(client)
    return asyncio.run(go())


def test_analyze_image_sends_image_and_parses_json():
    seen = {}

    async def handler(request):
        seen["body"] = await request.json()
        seen["auth"] = request.headers["Authorization"]
        return web.json_response({"choices": [{"message": {"content": '```json\n{"items": []}\n```'}}]})

    out = _run_with_server(handler, lambda c: c.analyze_image("describe", b"img", system="sys"))
    assert out == {"items": []}
    body = seen["body"]
    assert seen["auth"] == "Bearer k" and body["chat_template_kwargs"] == {"enable_thinking": False}
    assert body["messages"][0]["role"] == "system"
    assert body["messages"][1]["content"][1]["type"] == "image_url"


def test_retries_on_server_error_then_succeeds(monkeypatch):
    async def nosleep(_):
        pass
    monkeypatch.setattr(llm.asyncio, "sleep", nosleep)
    calls = {"n": 0}

    async def handler(request):
        calls["n"] += 1
        if calls["n"] < 3:
            return web.Response(status=503)
        return web.json_response({"choices": [{"message": {"content": "ok"}}]})

    assert _run_with_server(handler, lambda c: c.chat([{"role": "user", "content": "hi"}])) == "ok"
    assert calls["n"] == 3


def test_client_error_is_not_retried_and_empty_content_fails(monkeypatch):
    async def nosleep(_):
        pass
    monkeypatch.setattr(llm.asyncio, "sleep", nosleep)
    calls = {"n": 0}

    async def bad(request):
        calls["n"] += 1
        return web.Response(status=400, text="bad")

    with pytest.raises(llm.LLMError):
        _run_with_server(bad, lambda c: c.chat([{"role": "user", "content": "x"}]))
    assert calls["n"] == 1

    async def empty(request):
        return web.json_response({"choices": [{"message": {"content": "", "reasoning_content": "..."}}]})

    with pytest.raises(llm.LLMError):
        _run_with_server(empty, lambda c: c.chat([{"role": "user", "content": "x"}], retries=0))


def test_meal_tables_exist():
    from atomhealth import app
    cols = {r["name"] for r in app.db.execute("PRAGMA table_info(meals)")}
    assert {"ts", "kcal", "protein_g", "status", "photo_path", "raw_json"} <= cols
    assert app.db.execute("PRAGMA table_info(meal_items)").fetchall()
