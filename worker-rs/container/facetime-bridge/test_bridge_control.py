import importlib.util
import json
import os
import sys
import types
import unittest
from http.client import HTTPConnection
from pathlib import Path
from threading import Thread
from unittest.mock import patch


def _module(name):
    value = types.ModuleType(name)
    sys.modules[name] = value
    return value


_module("agora")
_module("agora.rtc")
websockets = _module("websockets")


async def _connect(*args, **kwargs):
    raise AssertionError("socket should not open in this test")


websockets.connect = _connect
base = _module("agora.rtc.agora_base")
base.AudioProfileType = types.SimpleNamespace(AUDIO_PROFILE_DEFAULT=1)
base.AudioPublishType = types.SimpleNamespace(AUDIO_PUBLISH_TYPE_PCM=1)
base.AudioScenarioType = types.SimpleNamespace(AUDIO_SCENARIO_AI_SERVER=1)
base.ChannelProfileType = types.SimpleNamespace(CHANNEL_PROFILE_LIVE_BROADCASTING=1)
base.ClientRoleType = types.SimpleNamespace(CLIENT_ROLE_BROADCASTER=1)
base.VideoPublishType = types.SimpleNamespace(VIDEO_PUBLISH_TYPE_NONE=1)


class _AudioSubscriptionOptions:
    def __init__(self, **values):
        self.values = values


class _RtcConnectionPublishConfig:
    def __init__(self, **values):
        self.values = values


base.AudioSubscriptionOptions = _AudioSubscriptionOptions
base.RtcConnectionPublishConfig = _RtcConnectionPublishConfig
service_module = _module("agora.rtc.agora_service")


class _ServiceConfig:
    pass


class _RtcConfig:
    def __init__(self, **values):
        self.values = values


class _Service:
    pass


service_module.AgoraService = _Service
service_module.AgoraServiceConfig = _ServiceConfig
service_module.RTCConnConfig = _RtcConfig
observer_module = _module("agora.rtc.audio_frame_observer")


class _Observer:
    pass


observer_module.IAudioFrameObserver = _Observer
spec = importlib.util.spec_from_file_location(
    "facetime_bridge", Path(__file__).with_name("bridge.py")
)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class ControlAuthTest(unittest.TestCase):
    def test_control_plane_requires_bearer_token(self):
        started = __import__("asyncio").Event()
        loop = __import__("asyncio").new_event_loop()
        instance = bridge.Bridge()
        bridge.ControlHandler.loop = loop
        bridge.ControlHandler.bridge = instance
        bridge.ControlHandler.bridge_started = started

        with patch.dict(os.environ, {"CONTROL_TOKEN": "expected-secret"}, clear=False):
            server = bridge.ThreadingHTTPServer(
                ("127.0.0.1", 0), bridge.ControlHandler
            )
            port = server.server_address[1]
            thread = Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                denied = HTTPConnection("127.0.0.1", port, timeout=2)
                denied.request("POST", "/start", body="{}", headers={"content-type": "application/json"})
                denied_response = denied.getresponse()
                self.assertEqual(denied_response.status, 401)
                self.assertEqual(json.loads(denied_response.read()), {"error": "unauthorized"})
                denied.close()

                wrong = HTTPConnection("127.0.0.1", port, timeout=2)
                wrong.request(
                    "POST",
                    "/start",
                    body="{}",
                    headers={
                        "content-type": "application/json",
                        "authorization": "Bearer wrong-secret",
                    },
                )
                wrong_response = wrong.getresponse()
                self.assertEqual(wrong_response.status, 401)
                wrong.close()

                ok = HTTPConnection("127.0.0.1", port, timeout=2)
                ok.request(
                    "POST",
                    "/start",
                    body="{}",
                    headers={
                        "content-type": "application/json",
                        "authorization": "Bearer expected-secret",
                    },
                )
                ok_response = ok.getresponse()
                self.assertEqual(ok_response.status, 200)
                self.assertEqual(json.loads(ok_response.read()), {"started": True})
                ok.close()
            finally:
                server.shutdown()
                server.server_close()
                loop.close()


if __name__ == "__main__":
    unittest.main()
