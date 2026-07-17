#!/usr/bin/env python3
"""Repeatable two-browser acceptance test for the local friend messaging flow."""

from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import time
import urllib.request
from pathlib import Path

from playwright.sync_api import Page, expect, sync_playwright


def available_tcp_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / "work"
EVIDENCE = WORK / "e2e-evidence"
REGISTRY = WORK / "e2e-registry.json"
RESULT = WORK / "e2e-acceptance-result.json"
RELAY_PORT = int(os.environ.get("MACPET_E2E_RELAY_PORT") or available_tcp_port())
WEB_PORT = int(os.environ.get("MACPET_E2E_WEB_PORT") or available_tcp_port())
if RELAY_PORT == WEB_PORT:
    raise ValueError("Relay and web acceptance ports must be different")
RELAY_URL = f"ws://127.0.0.1:{RELAY_PORT}/ws"
WEB_URL = f"http://127.0.0.1:{WEB_PORT}/web/?relay={RELAY_URL}"
CHROME_EXECUTABLE = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
MESSAGE_STORAGE_KEY = "macpet-web-messages"


def wait_until(description: str, predicate, timeout: float = 10.0):
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except Exception as error:  # noqa: BLE001 - retain the last diagnostic
            last_error = error
        time.sleep(0.05)
    suffix = f": {last_error}" if last_error else ""
    raise AssertionError(f"Timed out waiting for {description}{suffix}")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def contains_message(value, message_id: str, body: str) -> bool:
    if isinstance(value, dict):
        if value.get("id") == message_id and value.get("body") == body:
            return True
        return any(contains_message(item, message_id, body) for item in value.values())
    if isinstance(value, list):
        return any(contains_message(item, message_id, body) for item in value)
    return False


def wait_http(url: str, timeout: float = 10.0) -> None:
    def healthy() -> bool:
        with urllib.request.urlopen(url, timeout=1) as response:
            return response.status == 200

    wait_until(f"HTTP 200 from {url}", healthy, timeout)


def start_process(command: list[str], env: dict[str, str] | None = None):
    return subprocess.Popen(
        command,
        cwd=ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )


def stop_process(process: subprocess.Popen | None) -> str:
    if process is None:
        return ""
    if process.poll() is None:
        try:
            process.terminate()
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                process.kill()
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
    return process.stdout.read() if process.stdout else ""


def wait_for_owned_listener(
    process: subprocess.Popen, port: int, label: str, timeout: float = 10.0
) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError(f"{label} exited before listening on port {port}")
        probe = subprocess.run(
            [
                "lsof",
                "-nP",
                "-a",
                "-p",
                str(process.pid),
                f"-iTCP:{port}",
                "-sTCP:LISTEN",
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        if probe.returncode == 0:
            return
        time.sleep(0.05)
    raise AssertionError(f"{label} PID {process.pid} did not own port {port}")


def verify_started_process(
    process: subprocess.Popen, port: int, health_url: str, label: str
) -> subprocess.Popen:
    try:
        wait_for_owned_listener(process, port, label)
        wait_http(health_url)
        return process
    except Exception as error:
        output = stop_process(process)
        detail = f"\n{output.strip()}" if output.strip() else ""
        raise AssertionError(f"{label} startup failed{detail}") from error


def start_relay():
    env = os.environ.copy()
    env["PORT"] = str(RELAY_PORT)
    env["MACPET_REGISTRY_PATH"] = str(REGISTRY)
    process = start_process(["node", "relay/server.mjs"], env)
    return verify_started_process(
        process,
        RELAY_PORT,
        f"http://127.0.0.1:{RELAY_PORT}/health",
        "Relay",
    )


def start_web():
    process = start_process(
        ["python3", "-m", "http.server", str(WEB_PORT), "--directory", "."]
    )
    return verify_started_process(
        process,
        WEB_PORT,
        f"http://127.0.0.1:{WEB_PORT}/web/",
        "Web server",
    )


def read_registry() -> dict:
    return json.loads(REGISTRY.read_text(encoding="utf-8"))


def wait_registry(predicate, description: str, timeout: float = 10.0):
    return wait_until(
        description,
        lambda: (state if predicate(state := read_registry()) else None),
        timeout,
    )


def open_menu(page: Page) -> None:
    menu = page.locator("#operation-menu")
    if not menu.is_visible():
        page.locator("#menu-button").click()
    expect(menu).to_be_visible()


def set_name(page: Page, name: str) -> None:
    open_menu(page)
    field = page.locator("#web-name")
    field.fill(name)
    field.press("Tab")


def send_text(page: Page, body: str) -> None:
    open_menu(page)
    page.locator("#message-input").fill(body)
    page.locator("#send-message-button").click()
    expect(page.locator("#pet-message")).to_have_text("留言已发送", timeout=10_000)


def screenshot_pair(page_a: Page, page_b: Page, stage: str) -> list[str]:
    paths = [EVIDENCE / f"{stage}-a.png", EVIDENCE / f"{stage}-b.png"]
    page_a.screenshot(path=str(paths[0]), full_page=True)
    page_b.screenshot(path=str(paths[1]), full_page=True)
    return [str(path.relative_to(ROOT)) for path in paths]


def command_evidence(command: list[str], tail_lines: int = 24) -> dict:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    output = "\n".join(
        part.strip() for part in [completed.stdout, completed.stderr] if part.strip()
    )
    return {
        "command": command,
        "exit_code": completed.returncode,
        "output_tail": "\n".join(output.splitlines()[-tail_lines:]),
    }


def run_regression_gate() -> tuple[dict, list[str]]:
    evidence = {
        "relay_tests": command_evidence(["npm", "test", "--prefix", "relay"], 36),
        "relay_js_syntax": command_evidence(["node", "--check", "relay/server.mjs"]),
        "web_js_syntax": command_evidence(["node", "--check", "web/app.js"]),
        "swift_build": command_evidence(["swift", "build"]),
        "diff_check": command_evidence(["git", "diff", "--check"]),
    }
    failures = [name for name, check in evidence.items() if check["exit_code"] != 0]
    return evidence, failures


def run() -> dict:
    WORK.mkdir(exist_ok=True)
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    REGISTRY.unlink(missing_ok=True)
    RESULT.unlink(missing_ok=True)

    relay = None
    web = None
    relay_logs: list[str] = []
    browser_observations: dict[str, list[str]] = {
        "console_errors_a": [],
        "console_errors_b": [],
        "expected_outage_errors_a": [],
        "expected_outage_errors_b": [],
        "page_errors_a": [],
        "page_errors_b": [],
    }
    outage_state = {"active": False}
    result: dict = {
        "accepted": False,
        "services": {},
        "identity": {},
        "friendship": {},
        "online_messages": {},
        "offline_restart": {},
        "duplicate_redelivery_recovery": {},
        "reload_persistence": {},
        "multi_tab_storage_merge": {},
        "friend_removal": {},
        "screenshots": [],
        "browser_observations": browser_observations,
    }

    try:
        relay = start_relay()
        web = start_web()
        result["services"] = {
            "relay_health": {"ok": True},
            "relay_port": RELAY_PORT,
            "web_port": WEB_PORT,
            "relay_pids": [relay.pid],
        }

        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(
                headless=True, executable_path=CHROME_EXECUTABLE
            )
            context_a = browser.new_context(viewport={"width": 1280, "height": 900})
            context_b = browser.new_context(viewport={"width": 1280, "height": 900})
            context_a.route("**/favicon.ico", lambda route: route.fulfill(status=204, body=""))
            context_b.route("**/favicon.ico", lambda route: route.fulfill(status=204, body=""))
            page_a = context_a.new_page()
            page_b = context_b.new_page()

            def record_console(side: str, message) -> None:
                if message.type != "error":
                    return
                expected_outage = (
                    outage_state["active"]
                    and RELAY_URL in message.text
                    and "ERR_CONNECTION_REFUSED" in message.text
                )
                key = f"expected_outage_errors_{side}" if expected_outage else f"console_errors_{side}"
                browser_observations[key].append(message.text)

            page_a.on("console", lambda message: record_console("a", message))
            page_b.on("console", lambda message: record_console("b", message))
            page_a.on(
                "pageerror",
                lambda error: browser_observations["page_errors_a"].append(str(error)),
            )
            page_b.on(
                "pageerror",
                lambda error: browser_observations["page_errors_b"].append(str(error)),
            )

            page_a.goto(WEB_URL, wait_until="domcontentloaded")
            page_b.goto(WEB_URL, wait_until="domcontentloaded")
            expect(page_a.locator("#copy-code-button")).to_have_text(
                re.compile(r"^\d{6}$"), timeout=10_000
            )
            expect(page_b.locator("#copy-code-button")).to_have_text(
                re.compile(r"^\d{6}$"), timeout=10_000
            )

            code_a = page_a.locator("#copy-code-button").inner_text()
            code_b = page_b.locator("#copy-code-button").inner_text()
            require(code_a != code_b, "The two browser contexts must have different identities")

            set_name(page_a, "验收甲")
            set_name(page_b, "验收乙")
            identity_state = wait_registry(
                lambda state: sorted(
                    identity["name"] for identity in state["identities"].values()
                )
                == ["验收乙", "验收甲"],
                "both deterministic identity names",
            )
            result["identity"] = {
                "independent_contexts": True,
                "pet_codes": [code_a, code_b],
                "names": sorted(
                    identity["name"] for identity in identity_state["identities"].values()
                ),
            }

            open_menu(page_a)
            page_a.locator("#pairing-code").fill(code_b)
            page_a.locator("#connect-button").click()
            expect(page_b.locator("#friend-request")).to_be_visible(timeout=10_000)
            expect(page_b.locator("#request-name")).to_have_text("验收甲 想添加你")
            page_b.locator("#accept-request-button").click()

            expect(page_a.locator("#pet-name")).to_have_text("验收乙", timeout=10_000)
            expect(page_b.locator("#pet-name")).to_have_text("验收甲", timeout=10_000)
            expect(page_a.locator("#connection-label")).to_have_text("在线", timeout=10_000)
            expect(page_b.locator("#connection-label")).to_have_text("在线", timeout=10_000)
            require(
                page_a.locator("#pet-message").inner_text() != "好友暂时不在线",
                "Client A cannot display an offline message while its friend is online",
            )
            require(
                page_b.locator("#pet-message").inner_text() != "好友暂时不在线",
                "Client B cannot display an offline message while its friend is online",
            )
            friendship_state = wait_registry(
                lambda state: state["requests"] == {},
                "friend request acknowledgements to clear persisted request",
            )
            result["friendship"] = {
                "a_sees": page_a.locator("#pet-name").inner_text(),
                "b_sees": page_b.locator("#pet-name").inner_text(),
                "both_online": True,
                "pending_requests": len(friendship_state["requests"]),
            }
            result["screenshots"].extend(screenshot_pair(page_a, page_b, "01-friends-online"))

            send_text(page_a, "甲到乙-在线文字")
            expect(page_b.locator("#pet-message")).to_have_text(
                "验收甲：甲到乙-在线文字", timeout=10_000
            )

            send_text(page_b, "乙到甲-在线文字")
            expect(page_a.locator("#pet-message")).to_have_text(
                "验收乙：乙到甲-在线文字", timeout=10_000
            )

            open_menu(page_a)
            page_a.locator('.sticker-button[title="sticker_love"]').click()
            expect(page_a.locator("#pet-message")).to_have_text("留言已发送", timeout=10_000)
            expect(page_b.locator("#pet-message")).to_have_text(
                "验收甲 发来 ❤️", timeout=10_000
            )
            online_state = wait_registry(
                lambda state: state["messages"] == {},
                "online message acknowledgements to clear persisted messages",
            )
            result["online_messages"] = {
                "a_to_b_text": "验收甲：甲到乙-在线文字",
                "b_to_a_text": "验收乙：乙到甲-在线文字",
                "a_to_b_sticker": "验收甲 发来 ❤️",
                "pending_messages": len(online_state["messages"]),
            }
            result["screenshots"].extend(screenshot_pair(page_a, page_b, "02-online-sticker"))

            open_menu(page_b)
            page_b.locator("#disconnect-button").click()
            expect(page_b.locator("#connection-label")).to_have_text("已断开", timeout=10_000)
            expect(page_a.locator("#connection-label")).to_have_text("好友离线", timeout=12_000)

            send_text(page_a, "离线跨重启留言")
            queued_state = wait_registry(
                lambda state: len(state["messages"]) == 1
                and next(iter(state["messages"].values()))["body"] == "离线跨重启留言",
                "one persisted offline message",
            )
            queued_message = next(iter(queued_state["messages"].values()))
            result["screenshots"].extend(screenshot_pair(page_a, page_b, "03-offline-queued"))

            outage_state["active"] = True
            relay_logs.append(stop_process(relay))
            relay = None
            persisted_after_stop = read_registry()
            require(
                queued_message["id"] in persisted_after_stop["messages"],
                "The offline message must remain persisted after Relay shutdown",
            )

            relay = start_relay()
            result["services"]["relay_pids"].append(relay.pid)
            require(
                len(set(result["services"]["relay_pids"])) == 2,
                "Relay restart must use a different child PID",
            )
            expect(page_a.locator("#connection-label")).to_have_text(
                "好友离线", timeout=15_000
            )
            outage_state["active"] = False
            require(
                queued_message["id"] in read_registry()["messages"],
                "The offline message must survive Relay restart until recipient ACK",
            )

            open_menu(page_b)
            expect(page_b.locator("#disconnect-button")).to_have_text("重新连接")
            page_b.locator("#disconnect-button").click()
            expect(page_b.locator("#pet-message")).to_have_text(
                "验收甲：离线跨重启留言", timeout=15_000
            )
            expect(page_a.locator("#connection-label")).to_have_text("在线", timeout=10_000)
            expect(page_b.locator("#connection-label")).to_have_text("在线", timeout=10_000)
            final_state = wait_registry(
                lambda state: state["messages"] == {},
                "recipient ACK to clear the persisted offline queue",
            )
            result["offline_restart"] = {
                "message_id": queued_message["id"],
                "queued_before_restart": True,
                "persisted_across_restart": True,
                "delivered_text": page_b.locator("#pet-message").inner_text(),
                "pending_messages_after_ack": len(final_state["messages"]),
                "both_online_after_reconnect": True,
            }
            result["screenshots"].extend(screenshot_pair(page_a, page_b, "04-offline-redelivered"))

            page_b.evaluate(
                "storageKey => localStorage.removeItem(storageKey)",
                MESSAGE_STORAGE_KEY,
            )
            page_a.evaluate(
                """payload => new Promise((resolve, reject) => {
                    const relayURL = new URLSearchParams(location.search).get('relay');
                    const duplicateSocket = new WebSocket(relayURL);
                    const timeout = setTimeout(() => {
                        duplicateSocket.close();
                        reject(new Error('duplicate redelivery timed out'));
                    }, 10000);
                    duplicateSocket.addEventListener('open', () => {
                        const friends = JSON.parse(localStorage.getItem('macpet-web-friends') || '[]');
                        duplicateSocket.send(JSON.stringify({
                            type: 'presence-register',
                            peerID: localStorage.getItem('macpet-web-peer-id'),
                            authToken: localStorage.getItem('macpet-web-auth-token'),
                            name: localStorage.getItem('macpet-web-name'),
                            friendPeerIDs: friends.map(friend => friend.peerID)
                        }));
                    });
                    duplicateSocket.addEventListener('message', event => {
                        const message = JSON.parse(event.data);
                        if (message.type === 'presence-snapshot') {
                            duplicateSocket.send(JSON.stringify(payload));
                        } else if (message.type === 'friend-message-sent'
                            && message.messageID === payload.messageID) {
                            clearTimeout(timeout);
                            duplicateSocket.close();
                            resolve();
                        } else if (message.type === 'friend-message-failed'
                            && message.messageID === payload.messageID) {
                            clearTimeout(timeout);
                            duplicateSocket.close();
                            reject(new Error(message.message || 'duplicate redelivery failed'));
                        }
                    });
                    duplicateSocket.addEventListener('error', () => {
                        clearTimeout(timeout);
                        reject(new Error('duplicate redelivery socket failed'));
                    });
                })""",
                {
                    "type": "friend-message-send",
                    "messageID": queued_message["id"],
                    "targetPeerID": queued_message["toPeerID"],
                    "kind": queued_message["kind"],
                    "body": queued_message["body"],
                },
            )
            wait_registry(
                lambda state: state["messages"] == {},
                "duplicate redelivery ACK to clear the persisted queue",
            )
            recovered_storage_raw = page_b.evaluate(
                "storageKey => localStorage.getItem(storageKey)",
                MESSAGE_STORAGE_KEY,
            )
            recovered_storage = (
                json.loads(recovered_storage_raw)
                if recovered_storage_raw is not None
                else None
            )
            recovered_duplicate = contains_message(
                recovered_storage,
                queued_message["id"],
                queued_message["body"],
            )
            result["duplicate_redelivery_recovery"] = {
                "message_id": queued_message["id"],
                "storage_removed_while_page_running": True,
                "storage_recovered_before_ack": recovered_duplicate,
            }
            require(
                recovered_duplicate,
                "Duplicate redelivery was ACKed without restoring durable browser storage",
            )

            page_b.reload(wait_until="domcontentloaded")
            expect(page_b.locator("#connection-label")).to_have_text(
                "在线", timeout=15_000
            )
            stored_messages_raw = page_b.evaluate(
                "storageKey => localStorage.getItem(storageKey)",
                MESSAGE_STORAGE_KEY,
            )
            try:
                stored_messages = (
                    json.loads(stored_messages_raw)
                    if stored_messages_raw is not None
                    else None
                )
                storage_parse_error = None
            except json.JSONDecodeError as error:
                stored_messages = None
                storage_parse_error = str(error)

            storage_contains_message = contains_message(
                stored_messages,
                queued_message["id"],
                queued_message["body"],
            )
            open_menu(page_b)
            message_history = page_b.locator("#message-history")
            history_count = message_history.count()
            history_visible = history_count > 0 and message_history.is_visible()
            history_text = message_history.inner_text() if history_visible else ""
            history_contains_body = (
                history_visible and queued_message["body"] in history_text
            )
            result["reload_persistence"] = {
                "storage_key": MESSAGE_STORAGE_KEY,
                "expected_message_id": queued_message["id"],
                "expected_body": queued_message["body"],
                "storage_raw": stored_messages_raw,
                "storage_parse_error": storage_parse_error,
                "storage_contains_message": storage_contains_message,
                "history_element_count": history_count,
                "history_visible": history_visible,
                "history_text": history_text,
                "history_contains_body": history_contains_body,
                "reconnected_after_reload": True,
            }
            result["screenshots"].extend(
                screenshot_pair(page_a, page_b, "05-after-recipient-reload")
            )

            reload_failures = []
            if not storage_contains_message:
                reload_failures.append(
                    f"localStorage[{MESSAGE_STORAGE_KEY!r}] does not contain "
                    f"message id={queued_message['id']!r}, body={queued_message['body']!r}"
                )
            if not history_visible:
                reload_failures.append("#message-history is missing or not visible")
            elif not history_contains_body:
                reload_failures.append(
                    f"#message-history does not show body={queued_message['body']!r}"
                )
            require(
                reload_failures == [],
                "Reload persistence acceptance failed: " + "; ".join(reload_failures),
            )

            sender_peer_id = queued_message["fromPeerID"]
            memory_records = [
                {
                    "id": f"a{index:031x}",
                    "senderPeerID": sender_peer_id,
                    "senderName": "旧标签页",
                    "kind": "text",
                    "body": f"旧内存-{index}",
                    "createdAt": index,
                }
                for index in range(50)
            ]
            durable_records = [
                {
                    "id": f"b{index:031x}",
                    "senderPeerID": sender_peer_id,
                    "senderName": "新标签页",
                    "kind": "text",
                    "body": f"持久记录-{index}",
                    "createdAt": 1_000 + index,
                }
                for index in range(50)
            ]
            page_b.evaluate(
                "([key, records]) => localStorage.setItem(key, JSON.stringify(records))",
                [MESSAGE_STORAGE_KEY, memory_records],
            )
            page_b.reload(wait_until="domcontentloaded")
            expect(page_b.locator("#connection-label")).to_have_text(
                "在线", timeout=15_000
            )
            page_b.evaluate(
                "([key, records]) => localStorage.setItem(key, JSON.stringify(records))",
                [MESSAGE_STORAGE_KEY, durable_records],
            )
            send_text(page_a, "容量边界新留言")
            expect(page_b.locator("#pet-message")).to_have_text(
                "验收甲：容量边界新留言", timeout=10_000
            )
            merged_records = json.loads(page_b.evaluate(
                "key => localStorage.getItem(key)", MESSAGE_STORAGE_KEY
            ))
            merged_ids = {record["id"] for record in merged_records}
            durable_ids = {record["id"] for record in durable_records}
            memory_ids = {record["id"] for record in memory_records}
            result["multi_tab_storage_merge"] = {
                "stored_count": len(merged_records),
                "durable_records_retained": len(merged_ids & durable_ids),
                "stale_memory_records_retained": len(merged_ids & memory_ids),
                "incoming_retained": any(
                    record.get("body") == "容量边界新留言"
                    for record in merged_records
                ),
            }
            require(
                result["multi_tab_storage_merge"] == {
                    "stored_count": 50,
                    "durable_records_retained": 49,
                    "stale_memory_records_retained": 0,
                    "incoming_retained": True,
                },
                "Stale in-memory history displaced the newer durable browser history",
            )

            open_menu(page_a)
            page_a.locator("#disconnect-button").click()
            expect(page_a.locator("#connection-label")).to_have_text(
                "已断开", timeout=10_000
            )
            expect(page_b.locator("#connection-label")).to_have_text(
                "好友离线", timeout=12_000
            )
            open_menu(page_b)
            page_b.once("dialog", lambda dialog: dialog.accept())
            page_b.locator("#remove-friend-button").click()
            expect(page_b.locator("#pet-name")).to_have_text(
                "还没有好友", timeout=10_000
            )
            page_a.locator("#disconnect-button").click()
            expect(page_a.locator("#pet-name")).to_have_text(
                "还没有好友", timeout=15_000
            )
            removal_state = wait_registry(
                lambda state: len(state.get("removedFriendships", {})) == 1
                and all(
                    identity.get("friendPeerIDs", []) == []
                    for identity in state["identities"].values()
                ),
                "server-authoritative mutual friend removal",
            )
            result["friend_removal"] = {
                "both_clients_removed_friend": True,
                "offline_friend_reconciled_on_reconnect": True,
                "server_tombstones": len(removal_state["removedFriendships"]),
                "remaining_friend_links": sum(
                    len(identity.get("friendPeerIDs", []))
                    for identity in removal_state["identities"].values()
                ),
            }
            result["screenshots"].extend(
                screenshot_pair(page_a, page_b, "06-after-friend-removal")
            )

            context_a.close()
            context_b.close()
            browser.close()

        for key in ["console_errors_a", "console_errors_b", "page_errors_a", "page_errors_b"]:
            require(
                browser_observations[key] == [],
                f"Unexpected browser errors in {key}: {browser_observations[key]}",
            )
        result["regression"], regression_failures = run_regression_gate()
        if regression_failures:
            details = "\n".join(
                f"{name}:\n{result['regression'][name]['output_tail']}"
                for name in regression_failures
            )
            raise AssertionError(
                f"Regression gate failed: {', '.join(regression_failures)}\n{details}"
            )
        result["accepted"] = True
        return result
    finally:
        relay_logs.append(stop_process(relay))
        stop_process(web)
        result["relay_log"] = "\n".join(relay_logs).strip()
        RESULT.write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )


if __name__ == "__main__":
    acceptance_result = run()
    print(json.dumps(acceptance_result, ensure_ascii=False, indent=2))
