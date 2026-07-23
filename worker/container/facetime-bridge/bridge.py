"""FaceTime audio bridge: Agora channel <-> Gemini Live.

The Worker cannot do this: joining an Agora channel needs Agora's native
Server Gateway SDK, which is an x86_64 Linux shared object. This process is
deliberately a plain container with one HTTP control port and no Cloudflare
dependency, so the same image runs on Cloudflare Containers or on any VM if
the media path ever needs a fixed egress IP.

Everything secret arrives as process environment. Nothing is written to disk
except Agora's own log file, and nothing is retained after the call.
"""

import asyncio
import base64
import json
import logging
import os
import signal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread

import websockets

from agora.rtc.agora_base import (
    AudioProfileType,
    AudioPublishType,
    AudioScenarioType,
    AudioSubscriptionOptions,
    ChannelProfileType,
    ClientRoleType,
    RtcConnectionPublishConfig,
    VideoPublishType,
)
from agora.rtc.agora_service import AgoraService, AgoraServiceConfig, RTCConnConfig
from agora.rtc.audio_frame_observer import IAudioFrameObserver

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("facetime-bridge")

CONTROL_PORT = 8080

# The call's audio. 16 kHz mono is what Gemini Live accepts on input; its
# output comes back at 24 kHz and is pushed into the channel at that rate
# rather than resampled.
CALLER_SAMPLE_RATE = 16_000
MODEL_SAMPLE_RATE = 24_000
CHANNELS = 1

# Bounded queues. Audio backpressure is not fatal: if the far side of either
# queue stalls, dropping the oldest frames keeps the call live and merely
# loses a few tens of milliseconds. An unbounded queue would instead grow
# until the instance is killed.
CALLER_QUEUE_FRAMES = 50
MODEL_QUEUE_FRAMES = 100

# No single decoded audio chunk from the model is allowed to be larger than
# this. A malformed or hostile frame must not become an allocation.
MAX_DECODED_CHUNK_BYTES = 1 << 20

GEMINI_ENDPOINT = (
    "wss://generativelanguage.googleapis.com/ws/"
    "google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent"
)


def _env(name: str, default: str = "") -> str:
    return (os.environ.get(name) or default).strip()


def _drop_oldest_put(queue: "asyncio.Queue[bytes]", item: bytes) -> None:
    """Enqueue, evicting the oldest frame when the queue is already full."""
    while True:
        try:
            queue.put_nowait(item)
            return
        except asyncio.QueueFull:
            try:
                queue.get_nowait()
            except asyncio.QueueEmpty:
                return


class CallerAudioObserver(IAudioFrameObserver):
    """Caller audio arrives on an SDK thread; only copy here, never block."""

    def __init__(self, loop: asyncio.AbstractEventLoop, queue: "asyncio.Queue[bytes]"):
        super().__init__()
        self._loop = loop
        self._queue = queue

    def on_playback_audio_frame_before_mixing(
        self,
        agora_local_user,
        channel_id,
        uid,
        audio_frame,
        vad_result_state: int,
        vad_result_bytearray: bytearray,
    ) -> int:
        buffer = bytes(audio_frame.buffer)
        if 0 < len(buffer) <= MAX_DECODED_CHUNK_BYTES:
            self._loop.call_soon_threadsafe(_drop_oldest_put, self._queue, buffer)
        return 1

    def on_record_audio_frame(self, agora_local_user, channel_id, frame) -> int:
        return 0

    def on_playback_audio_frame(self, agora_local_user, channel_id, frame) -> int:
        return 0

    def on_ear_monitoring_audio_frame(self, agora_local_user, frame) -> int:
        return 0

    def on_get_audio_frame_position(self, agora_local_user) -> int:
        return 0


class Bridge:
    def __init__(self) -> None:
        self._stop = asyncio.Event()
        self._caller_audio: "asyncio.Queue[bytes]" = asyncio.Queue(CALLER_QUEUE_FRAMES)
        self._model_audio: "asyncio.Queue[bytes]" = asyncio.Queue(MODEL_QUEUE_FRAMES)

    def request_stop(self) -> None:
        self._stop.set()

    async def run(self) -> None:
        app_id = _env("AGORA_APP_ID")
        channel = _env("AGORA_CHANNEL_NAME")
        token = _env("AGORA_TOKEN")
        uid = _env("AGORA_UID", "0")
        api_key = _env("GEMINI_API_KEY")
        model = _env("GEMINI_LIVE_MODEL")
        if not (app_id and channel and token and api_key and model):
            raise SystemExit("bridge is missing required environment")

        service_config = AgoraServiceConfig()
        service_config.appid = app_id
        service_config.log_path = "/tmp/agora/agorasdk.log"
        service_config.log_file_size_kb = 1024
        service_config.data_dir = "/tmp/agora"
        service_config.config_dir = "/tmp/agora"
        os.makedirs("/tmp/agora", exist_ok=True)

        service = AgoraService()
        service.initialize(service_config)
        self._configure_proxy(service)

        publish_config = RtcConnectionPublishConfig(
            audio_profile=AudioProfileType.AUDIO_PROFILE_DEFAULT,
            audio_scenario=AudioScenarioType.AUDIO_SCENARIO_AI_SERVER,
            is_publish_audio=True,
            is_publish_video=False,
            audio_publish_type=AudioPublishType.AUDIO_PUBLISH_TYPE_PCM,
            video_publish_type=VideoPublishType.VIDEO_PUBLISH_TYPE_NONE,
        )
        conn_config = RTCConnConfig(
            client_role_type=ClientRoleType.CLIENT_ROLE_BROADCASTER,
            channel_profile=ChannelProfileType.CHANNEL_PROFILE_LIVE_BROADCASTING,
            auto_subscribe_audio=1,
            auto_subscribe_video=0,
            audio_recv_media_packet=0,
            audio_subs_options=AudioSubscriptionOptions(
                packet_only=0,
                pcm_data_only=1,
                bytes_per_sample=2,
                number_of_channels=CHANNELS,
                sample_rate_hz=CALLER_SAMPLE_RATE,
            ),
        )

        connection = service.create_rtc_connection(conn_config, publish_config)
        observer = CallerAudioObserver(asyncio.get_running_loop(), self._caller_audio)
        try:
            connection.connect(token, channel, uid)
            local_user = connection.get_local_user()
            local_user.register_audio_frame_observer(observer)
            local_user.subscribe_all_audio()
            await self._pump(api_key, model, connection)
        finally:
            # Teardown runs on every exit path, including cancellation: the
            # channel connection and the SDK instance both hold native
            # resources that outlive the coroutine otherwise.
            try:
                connection.disconnect()
            except Exception:
                logger.exception("disconnect failed")
            try:
                connection.release()
            except Exception:
                logger.exception("connection release failed")
            try:
                service.release()
            except Exception:
                logger.exception("service release failed")

    def _configure_proxy(self, service: AgoraService) -> None:
        """Force the media path onto Agora Cloud Proxy when asked.

        Direct mode sends media over UDP to arbitrary ports, which is the flow
        shape that fails on anycast egress. `tcp` pins everything to TLS 443.
        Cloud proxy has to be enabled by Agora on the App ID first, so a
        failure here is logged and the call still proceeds in direct mode.
        """
        mode = _env("AGORA_CLOUD_PROXY", "tcp").lower()
        if mode not in ("tcp", "udp"):
            return
        selector = 13 if mode == "tcp" else 1
        try:
            service.set_parameters('{"rtc.enable_proxy": true}')
            service.set_parameters('{"rtc.proxy_server":[%d,"",0]}' % selector)
        except Exception:
            logger.exception("cloud proxy %s could not be enabled", mode)

    async def _pump(self, api_key: str, model: str, connection) -> None:
        url = f"{GEMINI_ENDPOINT}?key={api_key}"
        async with websockets.connect(
            url, max_size=MAX_DECODED_CHUNK_BYTES * 2, ping_interval=20
        ) as socket:
            await socket.send(
                json.dumps(
                    {
                        "setup": {
                            "model": f"models/{model}",
                            "generationConfig": {"responseModalities": ["AUDIO"]},
                            "systemInstruction": {
                                "parts": [{"text": _env("GEMINI_SYSTEM_PROMPT")}]
                            },
                        }
                    }
                )
            )
            tasks = [
                asyncio.create_task(self._caller_to_model(socket)),
                asyncio.create_task(self._model_to_caller(socket)),
                asyncio.create_task(self._publish(connection)),
                asyncio.create_task(self._stop.wait()),
            ]
            try:
                await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            finally:
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)

    async def _caller_to_model(self, socket) -> None:
        while True:
            chunk = await self._caller_audio.get()
            await socket.send(
                json.dumps(
                    {
                        "realtimeInput": {
                            "mediaChunks": [
                                {
                                    "mimeType": (
                                        f"audio/pcm;rate={CALLER_SAMPLE_RATE}"
                                    ),
                                    "data": base64.b64encode(chunk).decode("ascii"),
                                }
                            ]
                        }
                    }
                )
            )

    async def _model_to_caller(self, socket) -> None:
        async for message in socket:
            if isinstance(message, bytes):
                message = message.decode("utf-8", "replace")
            try:
                event = json.loads(message)
            except ValueError:
                continue
            content = event.get("serverContent") or {}
            if content.get("interrupted"):
                # Barge-in: drop anything the model already queued so the
                # caller is not talked over by a stale reply.
                while not self._model_audio.empty():
                    self._model_audio.get_nowait()
                continue
            for part in (content.get("modelTurn") or {}).get("parts") or []:
                inline = part.get("inlineData") or {}
                data = inline.get("data")
                if not isinstance(data, str):
                    continue
                # Refuse before decoding: base64 is 4/3 of the payload, so
                # the length check bounds the allocation.
                if len(data) > MAX_DECODED_CHUNK_BYTES * 4 // 3:
                    logger.warning("dropping oversized model audio chunk")
                    continue
                try:
                    audio = base64.b64decode(data, validate=True)
                except ValueError:
                    continue
                if 0 < len(audio) <= MAX_DECODED_CHUNK_BYTES:
                    _drop_oldest_put(self._model_audio, audio)

    async def _publish(self, connection) -> None:
        """Feed the model's audio into the channel at roughly real time."""
        while True:
            chunk = await self._model_audio.get()
            connection.push_audio_pcm_data(chunk, MODEL_SAMPLE_RATE, CHANNELS)
            # Pace to the audio's own duration so the SDK's send buffer does
            # not run away when the model bursts.
            await asyncio.sleep(len(chunk) / (MODEL_SAMPLE_RATE * 2 * CHANNELS))


class ControlHandler(BaseHTTPRequestHandler):
    """Minimal control plane for the Durable Object: start and stop."""

    bridge_started: "asyncio.Event"
    loop: asyncio.AbstractEventLoop
    bridge: Bridge

    def log_message(self, fmt, *args):  # noqa: A003 - stdlib signature
        logger.info("control %s", fmt % args)

    def _respond(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:  # noqa: N802 - stdlib signature
        length = int(self.headers.get("content-length") or 0)
        if length > 4096:
            self._respond(413, {"error": "too large"})
            return
        self.rfile.read(length)
        if self.path == "/start":
            self.loop.call_soon_threadsafe(type(self).bridge_started.set)
            self._respond(200, {"started": True})
        elif self.path == "/stop":
            self.loop.call_soon_threadsafe(type(self).bridge.request_stop)
            self._respond(200, {"stopped": True})
        else:
            self._respond(404, {"error": "not found"})


async def main() -> None:
    loop = asyncio.get_running_loop()
    bridge = Bridge()
    started = asyncio.Event()

    ControlHandler.loop = loop
    ControlHandler.bridge = bridge
    ControlHandler.bridge_started = started

    server = ThreadingHTTPServer(("0.0.0.0", CONTROL_PORT), ControlHandler)
    Thread(target=server.serve_forever, daemon=True).start()

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, bridge.request_stop)

    max_seconds = int(_env("MAX_SESSION_SECONDS", "600") or "600")
    try:
        # If the control plane never says start, exit rather than idle: an
        # orphaned instance still costs money.
        await asyncio.wait_for(started.wait(), timeout=60)
        await asyncio.wait_for(bridge.run(), timeout=max_seconds)
    except asyncio.TimeoutError:
        logger.info("session ended on its deadline")
    finally:
        server.shutdown()


if __name__ == "__main__":
    asyncio.run(main())
