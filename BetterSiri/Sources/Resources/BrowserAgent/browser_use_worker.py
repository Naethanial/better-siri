#!/usr/bin/env python3

import asyncio
import base64
import json
import os
import re
import sys
import tempfile
import traceback
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Awaitable, Callable, Dict, Optional


_JSON_STDOUT = sys.stdout
# Route all non-protocol logs to stderr, keeping stdout clean JSON-only.
sys.stdout = sys.stderr


def _write(obj: Dict[str, Any]) -> None:
    _JSON_STDOUT.write(json.dumps(obj, ensure_ascii=True) + "\n")
    _JSON_STDOUT.flush()


def _err(id_: Optional[str], message: str, *, tb: Optional[str] = None) -> None:
    payload: Dict[str, Any] = {"message": message}
    if tb:
        payload["traceback"] = tb
    _write({"id": id_, "type": "error", "payload": payload})


@dataclass
class WorkerState:
    browser: Any = None
    agent: Any = None
    run_task: Optional[asyncio.Task] = None
    current_run_id: Optional[str] = None
    browser_user_data_dir: Optional[str] = None
    chrome_executable_path: Optional[str] = None
    chrome_args: list[str] = field(default_factory=list)
    profile_directory: Optional[str] = None


STATE = WorkerState()


_SPECIAL_KEY_PATTERN = re.compile(r"\{([^{}]+)\}")


def _normalize_send_keys_token(token: str) -> Optional[str]:
    """Map common {Enter}-style placeholders to browser_use send_keys values.

    browser_use supports a dedicated `send_keys` action. Some LLMs will instead
    embed placeholders like `{Enter}` inside typed text. If we see one of these
    known placeholders, we convert it into `send_keys` so it behaves like a real
    keypress.
    """

    t = token.strip()
    if not t:
        return None

    lower = t.lower()

    simple_map = {
        "enter": "Enter",
        "return": "Enter",
        "tab": "Tab",
        "escape": "Escape",
        "esc": "Escape",
        "backspace": "Backspace",
        "delete": "Delete",
        "space": "Space",
        "pagedown": "PageDown",
        "pageup": "PageUp",
        "arrowup": "ArrowUp",
        "arrowdown": "ArrowDown",
        "arrowleft": "ArrowLeft",
        "arrowright": "ArrowRight",
        "home": "Home",
        "end": "End",
    }

    if lower in simple_map:
        return simple_map[lower]

    # Support modifier shortcuts like {Ctrl+L}, {Cmd+V}, {Shift+Tab}.
    if "+" in t:
        parts = [p.strip() for p in t.split("+") if p.strip()]
        if not parts:
            return None

        mods: list[str] = []
        key: Optional[str] = None
        for part in parts:
            pl = part.lower()
            if pl in ("ctrl", "control"):
                mods.append("Control")
            elif pl in ("cmd", "command", "meta"):
                mods.append("Meta")
            elif pl in ("alt", "option"):
                mods.append("Alt")
            elif pl == "shift":
                mods.append("Shift")
            else:
                key = part

        if key is None:
            return None

        # Normalize single letters to lower-case.
        if len(key) == 1:
            key = key.lower()

        return "+".join(mods + [key])

    return None


def _emit(run_id: str, payload: Dict[str, Any]) -> None:
    _write({"id": run_id, "type": "run_task.event", "payload": payload})


def _run_artifacts_dir(run_id: str) -> Path:
    base = Path(tempfile.gettempdir()) / "bettersiri-browser-agent" / run_id
    base.mkdir(parents=True, exist_ok=True)
    return base


def _persist_screenshot(*, run_id: str, step: int, screenshot_base64: str) -> Dict[str, Any]:
    artifacts_dir = _run_artifacts_dir(run_id)
    image_bytes = base64.b64decode(screenshot_base64)

    png_path = artifacts_dir / f"step-{step:04d}.png"
    png_path.write_bytes(image_bytes)

    thumb_path: Optional[Path] = None
    try:
        from PIL import Image  # type: ignore

        with Image.open(png_path) as img:
            img = img.convert("RGB")
            max_width = 640
            if img.width > max_width:
                ratio = max_width / float(img.width)
                new_size = (max_width, int(img.height * ratio))
                img = img.resize(new_size)

            thumb_path = artifacts_dir / f"step-{step:04d}-thumb.jpg"
            img.save(thumb_path, format="JPEG", quality=65, optimize=True)
    except Exception:
        # Thumbnailing is best-effort.
        thumb_path = None

    payload: Dict[str, Any] = {
        "path": str(png_path),
    }
    if thumb_path is not None:
        payload["thumb_path"] = str(thumb_path)
    return payload


async def _maybe_import_browser_use() -> Any:
    try:
        import browser_use  # type: ignore

        return browser_use
    except Exception as e:
        raise RuntimeError(
            "browser_use is not installed. Install with: pip install browser-use && uvx browser-use install"
        ) from e


def _default_chrome_executable_path() -> Optional[str]:
    candidates = [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Google Chrome Beta.app/Contents/MacOS/Google Chrome Beta",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "/Applications/Arc.app/Contents/MacOS/Arc",
        "/Applications/Helium.app/Contents/MacOS/Helium",
    ]
    for path in candidates:
        if os.path.exists(path):
            return path
    return None


def _normalize_chrome_args(args: Any) -> list[str]:
    if not isinstance(args, list):
        return []
    out: list[str] = []
    for item in args:
        if isinstance(item, str):
            s = item.strip()
            if s:
                out.append(s)
    return out


def _check_profile_lock(user_data_dir: Optional[str]) -> None:
    if not user_data_dir:
        return

    lock_path = os.path.join(user_data_dir, "SingletonLock")
    if not os.path.exists(lock_path):
        return

    try:
        import fcntl  # type: ignore
    except Exception:
        # Best-effort; if we can't check locking, don't block.
        return

    try:
        fd = os.open(lock_path, os.O_RDWR)
    except Exception:
        return

    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as e:
            raise RuntimeError(
                "Selected browser profile is already in use. Close the other browser instance using this profile and try again."
            ) from e
        finally:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            except Exception:
                pass
    finally:
        try:
            os.close(fd)
        except Exception:
            pass


async def _safe_awaitable_call(target: Any, method_name: str) -> bool:
    fn = getattr(target, method_name, None)
    if fn is None:
        return False
    try:
        res = fn()
        if asyncio.iscoroutine(res):
            await res
        return True
    except Exception:
        return False


async def _safe_stop_browser(browser: Any) -> None:
    # browser_use has changed names across versions; be defensive.
    for method in ("stop", "close", "shutdown", "terminate"):
        if await _safe_awaitable_call(browser, method):
            return


async def _safe_kill_browser(browser: Any) -> None:
    # Prefer a hard kill when the user explicitly asks to close the agent browser.
    for method in ("kill", "stop", "close", "shutdown", "terminate"):
        if await _safe_awaitable_call(browser, method):
            return


async def _ensure_browser(
    *,
    user_data_dir: Optional[str],
    headless: bool,
    window_size: Optional[Dict[str, int]],
) -> Any:
    if STATE.browser is not None:
        try:
            pages = await STATE.browser.get_pages()
            if not pages:
                await STATE.browser.new_page("about:blank")
            return STATE.browser
        except Exception:
            try:
                await _safe_kill_browser(STATE.browser)
            except Exception:
                pass
            STATE.browser = None
            STATE.browser_user_data_dir = None

    browser_use = await _maybe_import_browser_use()

    Browser = getattr(browser_use, "Browser")

    executable_path = STATE.chrome_executable_path or os.environ.get("BROWSER_USE_CHROME_PATH") or _default_chrome_executable_path()

    _check_profile_lock(user_data_dir)

    # Keep one real window alive across tasks.
    # Use a dummy user_data_dir by default to avoid locking the user's real profile.
    args = ["--disable-session-crashed-bubble"]
    for a in STATE.chrome_args or []:
        if a not in args:
            args.append(a)

    if STATE.profile_directory:
        flag = f"--profile-directory={STATE.profile_directory}"
        if flag not in args:
            args.append(flag)

    browser_kwargs: Dict[str, Any] = {
        "is_local": True,
        "headless": headless,
        "keep_alive": True,
        "user_data_dir": user_data_dir,
        "window_size": window_size,
        "args": args,
        # Force local browser usage; we want to control installed Chromium apps.
        "use_cloud": False,
        "cloud_browser": False,
    }

    # Prefer an explicit Chrome path if present, but allow browser_use to manage
    # its own Chromium install (via `browser-use install`) when system Chrome is
    # unavailable.
    if executable_path is not None:
        browser_kwargs["executable_path"] = executable_path

    try:
        browser = Browser(**browser_kwargs)
    except TypeError as e:
        # browser_use has changed constructor kwargs across versions; gracefully
        # fall back when optional args are unsupported.
        msg = str(e)
        reduced = dict(browser_kwargs)
        for key in ("is_local", "use_cloud", "cloud_browser"):
            if f"'{key}'" in msg:
                reduced.pop(key, None)

        try:
            browser = Browser(**reduced)
        except TypeError:
            minimal = {
                "headless": headless,
                "keep_alive": True,
                "user_data_dir": user_data_dir,
                "window_size": window_size,
                "args": args,
            }
            if executable_path is not None:
                minimal["executable_path"] = executable_path
            browser = Browser(**minimal)

    STATE.browser = browser
    STATE.browser_user_data_dir = user_data_dir
    STATE.chrome_executable_path = executable_path

    # Launch the browser immediately so the app can reuse one window.
    await browser.start()
    return browser


async def handle_open_browser(cmd_id: str, payload: Dict[str, Any]) -> None:
    try:
        user_data_dir = payload.get("user_data_dir")
        headless = bool(payload.get("headless", False))
        window_size = payload.get("window_size")
        chrome_executable_path = payload.get("chrome_executable_path")
        chrome_args = _normalize_chrome_args(payload.get("chrome_args"))
        profile_directory = payload.get("profile_directory")

        if chrome_executable_path:
            STATE.chrome_executable_path = chrome_executable_path
        if chrome_args:
            STATE.chrome_args = chrome_args
        else:
            STATE.chrome_args = []
        if profile_directory and isinstance(profile_directory, str) and profile_directory.strip():
            STATE.profile_directory = profile_directory.strip()
        else:
            STATE.profile_directory = None

        await _ensure_browser(user_data_dir=user_data_dir, headless=headless, window_size=window_size)
        _write({"id": cmd_id, "type": "open_browser.ok", "payload": {"status": "ok"}})
    except Exception as e:
        message = "Failed to open browser"
        if str(e):
            message = f"{message}: {e}"
        _write(
            {
                "id": cmd_id,
                "type": "open_browser.error",
                "payload": {"message": message, "traceback": traceback.format_exc()},
            }
        )


async def _run_agent(
    *,
    run_id: str,
    task: str,
    max_steps: Optional[int],
    use_browser_use_llm: bool,
    browser_use_model: Optional[str],
    openai_api_key: Optional[str],
    openai_base_url: Optional[str],
    openai_model: Optional[str],
    headless: bool,
    window_size: Optional[Dict[str, int]],
) -> None:
    try:
        browser_use = await _maybe_import_browser_use()

        Agent = getattr(browser_use, "Agent")
        ChatBrowserUse = getattr(browser_use, "ChatBrowserUse")
        ChatOpenAI = getattr(browser_use, "ChatOpenAI", None)

        llm = None
        if use_browser_use_llm:
            if not os.environ.get("BROWSER_USE_API_KEY"):
                raise RuntimeError(
                    "Browser Use Cloud mode requires BROWSER_USE_API_KEY. Set the Browser Use API key in Settings or switch Browser agent LLM to OpenRouter."
                )

            if browser_use_model:
                try:
                    llm = ChatBrowserUse(model=browser_use_model)
                except TypeError:
                    llm = ChatBrowserUse()
            else:
                llm = ChatBrowserUse()
        else:
            # OpenAI-compatible mode (OpenRouter base_url, etc.)
            if ChatOpenAI is None:
                raise RuntimeError("ChatOpenAI not available in installed browser_use")

            api_key = (openai_api_key or "").strip() or os.environ.get("OPENAI_API_KEY") or os.environ.get("OPENAI_KEY")
            if not api_key:
                raise RuntimeError(
                    "Missing OpenRouter/OpenAI API key. Set your OpenRouter API key in Settings or switch Browser agent LLM to Browser Use Cloud."
                )

            model = (openai_model or "").strip() or "openai/gpt-4o-mini"
            base_url = (openai_base_url or "").strip() or None

            headers = {"X-Title": "BetterSiri"}

            llm = ChatOpenAI(
                model=model,
                api_key=api_key,
                base_url=base_url,
                default_headers=headers,
            )

        browser = await _ensure_browser(
            user_data_dir=STATE.browser_user_data_dir,
            headless=headless,
            window_size=window_size,
        )

        step_index = 0
        reported_model_outputs = 0
        reported_action_results = 0

        async def on_step_start(agent: Any) -> None:
            nonlocal step_index
            step_index += 1
            try:
                state = await agent.browser_session.get_browser_state_summary()
                _emit(
                    run_id,
                    {
                        "event": "step_start",
                        "step": step_index,
                        "url": getattr(state, "url", None),
                        "title": getattr(state, "title", None),
                    },
                )
            except Exception:
                _emit(run_id, {"event": "step_start", "step": step_index})

        async def on_step_end(agent: Any) -> None:
            nonlocal reported_model_outputs, reported_action_results

            # Model output (memory + planned actions)
            try:
                outputs = agent.history.model_outputs() if agent.history is not None else []
                new_outputs = outputs[reported_model_outputs:]
                for output in new_outputs:
                    dumped = output.model_dump(exclude_none=True)
                    _emit(
                        run_id,
                        {
                            "event": "model_output",
                            "step": step_index,
                            "memory": dumped.get("memory"),
                            "next_goal": dumped.get("next_goal"),
                            "actions": dumped.get("action"),
                        },
                    )
                reported_model_outputs = len(outputs)
            except Exception:
                pass

            # Action results (what happened)
            try:
                results = agent.history.action_results() if agent.history is not None else []
                new_results = results[reported_action_results:]
                for res in new_results:
                    text = getattr(res, "extracted_content", None) or getattr(res, "long_term_memory", None) or ""
                    error = getattr(res, "error", None)
                    if error:
                        _emit(
                            run_id,
                            {
                                "event": "action_result",
                                "step": step_index,
                                "status": "error",
                                "text": str(error),
                            },
                        )
                    elif text:
                        _emit(
                            run_id,
                            {
                                "event": "action_result",
                                "step": step_index,
                                "status": "ok",
                                "text": str(text),
                            },
                        )
                reported_action_results = len(results)
            except Exception:
                pass

            # Screenshot (viewport) for UI preview
            try:
                from browser_use.browser.events import ScreenshotEvent  # type: ignore

                screenshot_event = agent.browser_session.event_bus.dispatch(ScreenshotEvent(full_page=False))
                await screenshot_event
                screenshot_base64 = await screenshot_event.event_result(raise_if_any=True, raise_if_none=True)

                screenshot_payload = _persist_screenshot(
                    run_id=run_id,
                    step=step_index,
                    screenshot_base64=screenshot_base64,
                )
                _emit(
                    run_id,
                    {
                        "event": "screenshot",
                        "step": step_index,
                        **screenshot_payload,
                    },
                )
            except Exception:
                pass

            # Post-step state
            try:
                state = await agent.browser_session.get_browser_state_summary()
                _emit(
                    run_id,
                    {
                        "event": "step_end",
                        "step": step_index,
                        "url": getattr(state, "url", None),
                        "title": getattr(state, "title", None),
                    },
                )
            except Exception:
                _emit(run_id, {"event": "step_end", "step": step_index})

        agent = Agent(
            task=task,
            browser=browser,
            llm=llm,
            # Encourage the model to use native browser actions for key presses.
            extend_system_message=(
                "When extracting facts from a page (titles, numbers, form values), verify by using tools like evaluate() or reading the DOM. "
                "Do not rely solely on tab labels or URL hostnames as they may differ from the actual page title. "
                "When interacting with inputs, do not type placeholders like {Enter} or {Tab} into fields. Use the send_keys action for special keys instead."
            ),
        )

        # Some LLMs embed placeholders like `{Enter}` inside typed text. Convert those
        # into real `send_keys` actions so browser automation behaves correctly.
        orig_multi_act = agent.multi_act
        ActionModel = agent.ActionModel

        def _sanitize_actions(actions: list[Any]) -> list[Any]:
            sanitized: list[Any] = []
            for action in actions:
                try:
                    dumped = action.model_dump(exclude_unset=True)
                except Exception:
                    sanitized.append(action)
                    continue

                input_payload = dumped.get("input")
                if not isinstance(input_payload, dict):
                    sanitized.append(action)
                    continue

                raw_text = input_payload.get("text")
                if not isinstance(raw_text, str) or "{" not in raw_text or "}" not in raw_text:
                    sanitized.append(action)
                    continue

                matches = list(_SPECIAL_KEY_PATTERN.finditer(raw_text))
                if not matches:
                    sanitized.append(action)
                    continue

                index = input_payload.get("index")
                clear_value = input_payload.get("clear")
                has_typed_anything = False

                cursor = 0
                for match in matches:
                    prefix = raw_text[cursor : match.start()]
                    if prefix:
                        payload: Dict[str, Any] = {"index": index, "text": prefix}
                        if not has_typed_anything and clear_value is not None:
                            payload["clear"] = clear_value
                        sanitized.append(ActionModel.model_validate({"input": payload}))
                        has_typed_anything = True

                    token = match.group(1)
                    normalized = _normalize_send_keys_token(token)
                    if normalized is None:
                        # Unknown token; keep it literal.
                        literal = "{" + token + "}"
                        if literal:
                            payload = {"index": index, "text": literal}
                            if not has_typed_anything and clear_value is not None:
                                payload["clear"] = clear_value
                            sanitized.append(ActionModel.model_validate({"input": payload}))
                            has_typed_anything = True
                    else:
                        # Ensure the element is focused before sending keys.
                        if not has_typed_anything:
                            focus_payload: Dict[str, Any] = {"index": index, "text": ""}
                            if clear_value is not None:
                                focus_payload["clear"] = clear_value
                            sanitized.append(ActionModel.model_validate({"input": focus_payload}))
                            has_typed_anything = True

                        sanitized.append(ActionModel.model_validate({"send_keys": {"keys": normalized}}))

                    cursor = match.end()

                suffix = raw_text[cursor:]
                if suffix:
                    payload = {"index": index, "text": suffix}
                    sanitized.append(ActionModel.model_validate({"input": payload}))
                elif not has_typed_anything:
                    sanitized.append(action)

            return sanitized

        async def multi_act(actions: list[Any]):
            return await orig_multi_act(_sanitize_actions(actions))

        agent.multi_act = multi_act  # type: ignore[assignment]

        STATE.agent = agent

        _write({"id": run_id, "type": "run_task.event", "payload": {"event": "started"}})

        kwargs: Dict[str, Any] = {
            "on_step_start": on_step_start,
            "on_step_end": on_step_end,
        }
        if max_steps is not None:
            kwargs["max_steps"] = max_steps

        history = await agent.run(**kwargs)

        output_text: str
        final_result = getattr(history, "final_result", None)
        if callable(final_result):
            output_text = str(final_result())
        else:
            output_text = str(history)

        _write({"id": run_id, "type": "run_task.ok", "payload": {"output": output_text}})
    except asyncio.CancelledError:
        _write({"id": run_id, "type": "run_task.cancelled", "payload": {"status": "cancelled"}})
        raise
    except Exception:
        _write(
            {
                "id": run_id,
                "type": "run_task.error",
                "payload": {"message": "Browser task failed", "traceback": traceback.format_exc()},
            }
        )
    finally:
        STATE.agent = None


async def handle_run_task(cmd_id: str, payload: Dict[str, Any]) -> None:
    if STATE.run_task is not None and not STATE.run_task.done():
        _write(
            {
                "id": cmd_id,
                "type": "run_task.error",
                "payload": {"message": "A browser task is already running"},
            }
        )
        return

    task = str(payload.get("task", "")).strip()
    if not task:
        _write({"id": cmd_id, "type": "run_task.error", "payload": {"message": "Missing task"}})
        return

    max_steps = payload.get("max_steps")
    if max_steps is not None:
        try:
            max_steps = int(max_steps)
        except Exception:
            max_steps = None

    use_browser_use_llm = bool(payload.get("use_browser_use_llm", True))
    browser_use_model = payload.get("browser_use_model")
    if not isinstance(browser_use_model, str):
        browser_use_model = None
    else:
        browser_use_model = browser_use_model.strip() or None

    openai_api_key = payload.get("openai_api_key")
    if not isinstance(openai_api_key, str):
        openai_api_key = None
    else:
        openai_api_key = openai_api_key.strip() or None

    openai_base_url = payload.get("openai_base_url")
    if not isinstance(openai_base_url, str):
        openai_base_url = None
    else:
        openai_base_url = openai_base_url.strip() or None

    openai_model = payload.get("openai_model")
    if not isinstance(openai_model, str):
        openai_model = None
    else:
        openai_model = openai_model.strip() or None
    headless = bool(payload.get("headless", False))
    window_size = payload.get("window_size")

    STATE.current_run_id = cmd_id
    STATE.run_task = asyncio.create_task(
        _run_agent(
            run_id=cmd_id,
            task=task,
            max_steps=max_steps,
            use_browser_use_llm=use_browser_use_llm,
            browser_use_model=browser_use_model,
            openai_api_key=openai_api_key,
            openai_base_url=openai_base_url,
            openai_model=openai_model,
            headless=headless,
            window_size=window_size,
        )
    )

async def _extract_page_text(page: Any, max_chars: int) -> str:
    try:
        text = await page.evaluate("() => document.body ? (document.body.innerText || '') : ''")
        if isinstance(text, str):
            return text[:max_chars]
    except Exception:
        pass

    try:
        html = await page.content()
        if isinstance(html, str):
            # Very rough fallback; better than nothing if evaluate() fails.
            cleaned = re.sub(r"<[^>]+>", " ", html)
            cleaned = re.sub(r"\\s+", " ", cleaned).strip()
            return cleaned[:max_chars]
    except Exception:
        pass

    return ""


async def handle_get_tab_context(cmd_id: str, payload: Dict[str, Any]) -> None:
    try:
        include_active_text = bool(payload.get("include_active_text", True))
        max_chars = payload.get("max_chars")
        try:
            max_chars = int(max_chars) if max_chars is not None else 1800
        except Exception:
            max_chars = 1800
        max_chars = max(200, min(max_chars, 8000))

        browser = await _ensure_browser(
            user_data_dir=STATE.browser_user_data_dir,
            headless=False,
            window_size=None,
        )

        state = await browser.get_browser_state_summary()

        tabs: list[dict[str, Any]] = []
        for idx, tab in enumerate(getattr(state, "tabs", []) or []):
            tabs.append(
                {
                    "index": idx,
                    "title": getattr(tab, "title", None),
                    "url": getattr(tab, "url", None),
                    "target_id": getattr(tab, "target_id", None),
                }
            )

        # Derive active tab index from focused targetId when possible.
        active_index = None
        try:
            info = await browser.get_current_target_info()
            target_id = info.get("targetId") if isinstance(info, dict) else None
            if target_id:
                for t in tabs:
                    if t.get("target_id") == target_id:
                        active_index = t.get("index")
                        break
        except Exception:
            active_index = None

        if active_index is None and tabs:
            active_index = 0

        active_text_excerpt = None
        if include_active_text:
            try:
                page = await browser.get_current_page()
                if page is not None:
                    active_text_excerpt = await _extract_page_text(page, max_chars=max_chars)
            except Exception:
                active_text_excerpt = None

        _write(
            {
                "id": cmd_id,
                "type": "get_tab_context.ok",
                "payload": {
                    "tabs": tabs,
                    "active_index": active_index,
                    "active_text_excerpt": active_text_excerpt,
                },
            }
        )
    except Exception:
        _write(
            {
                "id": cmd_id,
                "type": "get_tab_context.error",
                "payload": {"message": "Failed to get tab context", "traceback": traceback.format_exc()},
            }
        )


async def handle_read_tab_text(cmd_id: str, payload: Dict[str, Any]) -> None:
    try:
        index = payload.get("index")
        try:
            index = int(index)
        except Exception:
            index = -1

        max_chars = payload.get("max_chars")
        try:
            max_chars = int(max_chars) if max_chars is not None else 4000
        except Exception:
            max_chars = 4000
        max_chars = max(200, min(max_chars, 16000))

        browser = await _ensure_browser(
            user_data_dir=STATE.browser_user_data_dir,
            headless=False,
            window_size=None,
        )

        state = await browser.get_browser_state_summary()
        tabs = getattr(state, "tabs", []) or []

        if index < 0 or index >= len(tabs):
            _write(
                {
                    "id": cmd_id,
                    "type": "read_tab_text.error",
                    "payload": {"message": f"Invalid tab index: {index}"},
                }
            )
            return

        # Switch focus to the requested tab (read-only; no navigation/click).
        try:
            from browser_use.browser.events import SwitchTabEvent  # type: ignore

            target_id = getattr(tabs[index], "target_id", None)
            if target_id:
                await browser.event_bus.dispatch(SwitchTabEvent(target_id=target_id))
        except Exception:
            pass

        page = await browser.get_current_page()
        if page is None:
            _write(
                {
                    "id": cmd_id,
                    "type": "read_tab_text.error",
                    "payload": {"message": "No active tab"},
                }
            )
            return

        text = await _extract_page_text(page, max_chars=max_chars)
        _write({"id": cmd_id, "type": "read_tab_text.ok", "payload": {"index": index, "text": text}})
    except Exception:
        _write(
            {
                "id": cmd_id,
                "type": "read_tab_text.error",
                "payload": {"message": "Failed to read tab text", "traceback": traceback.format_exc()},
            }
        )


async def handle_pause(cmd_id: str, payload: Dict[str, Any]) -> None:
    try:
        if STATE.agent is not None:
            STATE.agent.pause()
        _write({"id": cmd_id, "type": "pause.ok", "payload": {"status": "ok"}})
    except Exception:
        _write({"id": cmd_id, "type": "pause.error", "payload": {"traceback": traceback.format_exc()}})


async def handle_resume(cmd_id: str, payload: Dict[str, Any]) -> None:
    try:
        if STATE.agent is not None:
            STATE.agent.resume()
        _write({"id": cmd_id, "type": "resume.ok", "payload": {"status": "ok"}})
    except Exception:
        _write({"id": cmd_id, "type": "resume.error", "payload": {"traceback": traceback.format_exc()}})


async def handle_stop(cmd_id: str, payload: Dict[str, Any]) -> None:
    try:
        if STATE.run_task is not None and not STATE.run_task.done():
            STATE.run_task.cancel()
        _write({"id": cmd_id, "type": "stop.ok", "payload": {"status": "ok"}})
    except Exception:
        _write({"id": cmd_id, "type": "stop.error", "payload": {"traceback": traceback.format_exc()}})


async def handle_close_browser(cmd_id: str, payload: Dict[str, Any]) -> None:
    try:
        if STATE.run_task is not None and not STATE.run_task.done():
            STATE.run_task.cancel()

        if STATE.browser is not None:
            await _safe_kill_browser(STATE.browser)
        STATE.browser = None
        STATE.browser_user_data_dir = None
        _write({"id": cmd_id, "type": "close_browser.ok", "payload": {"status": "ok"}})
    except Exception:
        _write(
            {
                "id": cmd_id,
                "type": "close_browser.error",
                "payload": {"message": "Failed to close browser", "traceback": traceback.format_exc()},
            }
        )


async def handle_close_all_windows(cmd_id: str, payload: Dict[str, Any]) -> None:
    keep_session = bool(payload.get("keep_session", True))
    if not keep_session:
        await handle_close_browser(cmd_id, payload)
        return

    try:
        if STATE.run_task is not None and not STATE.run_task.done():
            STATE.run_task.cancel()

        if STATE.browser is None:
            _write({"id": cmd_id, "type": "close_all_windows.ok", "payload": {"status": "ok"}})
            return

        browser = STATE.browser
        try:
            # Ensure a connection exists.
            await browser.start()
        except Exception:
            pass

        pages = await browser.get_pages()
        if not pages:
            await browser.new_page("about:blank")
            _write({"id": cmd_id, "type": "close_all_windows.ok", "payload": {"status": "ok"}})
            return

        # Keep one page alive so the Chrome process stays open.
        keep_page = pages[0]
        for page in pages[1:]:
            try:
                await browser.close_page(page)
            except Exception:
                pass

        try:
            await keep_page.goto("about:blank")
        except Exception:
            pass

        _write({"id": cmd_id, "type": "close_all_windows.ok", "payload": {"status": "ok"}})
    except Exception:
        _write(
            {
                "id": cmd_id,
                "type": "close_all_windows.error",
                "payload": {"message": "Failed to close all windows", "traceback": traceback.format_exc()},
            }
        )


HANDLERS: Dict[str, Callable[[str, Dict[str, Any]], Awaitable[None]]] = {
    "open_browser": handle_open_browser,
    "run_task": handle_run_task,
    "get_tab_context": handle_get_tab_context,
    "read_tab_text": handle_read_tab_text,
    "pause": handle_pause,
    "resume": handle_resume,
    "stop": handle_stop,
    "close_browser": handle_close_browser,
    "close_all_windows": handle_close_all_windows,
}


async def main() -> None:
    _write({"type": "ready", "payload": {"pid": os.getpid()}})

    loop = asyncio.get_event_loop()
    reader = asyncio.StreamReader()
    protocol = asyncio.StreamReaderProtocol(reader)
    await loop.connect_read_pipe(lambda: protocol, sys.stdin)

    while True:
        line_bytes = await reader.readline()
        if not line_bytes:
            break
        try:
            line = line_bytes.decode("utf-8").strip()
        except Exception:
            continue
        if not line:
            continue

        try:
            msg = json.loads(line)
        except Exception:
            _err(None, "Invalid JSON")
            continue

        cmd_id = str(msg.get("id")) if msg.get("id") is not None else ""
        cmd_type = msg.get("type")
        payload = msg.get("payload") or {}

        if not cmd_type or cmd_type not in HANDLERS:
            _write(
                {
                    "id": cmd_id or None,
                    "type": "error",
                    "payload": {"message": f"Unknown command: {cmd_type}"},
                }
            )
            continue

        try:
            await HANDLERS[cmd_type](cmd_id, payload)
        except Exception:
            _err(cmd_id or None, "Handler crashed", tb=traceback.format_exc())


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
