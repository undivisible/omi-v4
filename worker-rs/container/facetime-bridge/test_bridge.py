import asyncio
import importlib.util
import os
import sys
import types
import unittest
from pathlib import Path
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


class _User:
    def __init__(self):
        self.subscribed = False

    def subscribe_all_audio(self):
        self.subscribed = True


class _Connection:
    def __init__(self):
        self.user = _User()
        self.observer = None
        self.observer_args = None

    def connect(self, *args):
        self.connected = args

    def register_audio_frame_observer(self, observer, enable_vad, vad_configure):
        self.observer = observer
        self.observer_args = (enable_vad, vad_configure)

    def get_local_user(self):
        return self.user

    def disconnect(self):
        self.disconnected = True

    def release(self):
        self.released = True


class _ServiceInstance:
    def __init__(self):
        self.connection = _Connection()

    def initialize(self, config):
        self.config = config

    def set_parameters(self, value):
        self.parameters = value

    def create_rtc_connection(self, config, publish):
        self.connection_config = config
        self.publish_config = publish
        return self.connection

    def release(self):
        self.released = True


class BridgeTest(unittest.IsolatedAsyncioTestCase):
    async def test_run_registers_the_remote_audio_observer_with_the_sdk_api(self):
        service = _ServiceInstance()
        instance = bridge.Bridge()

        async def pump(_, api_key, model, connection):
            self.assertEqual(api_key, "key")
            self.assertEqual(model, "model")
            self.assertIs(connection, service.connection)

        instance._pump = pump.__get__(instance, bridge.Bridge)
        with patch.object(bridge, "AgoraService", return_value=service), patch.dict(
            os.environ,
            {
                "AGORA_APP_ID": "app",
                "AGORA_CHANNEL_NAME": "channel",
                "AGORA_TOKEN": "token",
                "AGORA_UID": "42",
                "GEMINI_API_KEY": "key",
                "GEMINI_LIVE_MODEL": "model",
            },
            clear=True,
        ):
            await instance.run()

        self.assertEqual(service.connection.observer_args, (0, None))
        self.assertTrue(service.connection.user.subscribed)
        self.assertTrue(service.connection.disconnected)
        self.assertTrue(service.connection.released)


if __name__ == "__main__":
    unittest.main()
