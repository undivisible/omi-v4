import RustWorker, {
  AssistantAdmissionDo,
  ContainerStartupOptions,
  DeliveryCoordinator,
  FaceTimeBridge,
  IntoUnderlyingByteSource,
  IntoUnderlyingSink,
  IntoUnderlyingSource,
  MinifyConfig,
  R2Range,
  RateLimiterDo,
  SttAdmissionDo,
} from "./build/worker/shim.mjs";
import { shipTailEvents } from "./tail-export.mjs";

export default class extends RustWorker {
  tail(events, env, ctx) {
    ctx.waitUntil(shipTailEvents(env, events));
  }
}

export {
  AssistantAdmissionDo,
  ContainerStartupOptions,
  DeliveryCoordinator,
  FaceTimeBridge,
  IntoUnderlyingByteSource,
  IntoUnderlyingSink,
  IntoUnderlyingSource,
  MinifyConfig,
  R2Range,
  RateLimiterDo,
  SttAdmissionDo,
};
