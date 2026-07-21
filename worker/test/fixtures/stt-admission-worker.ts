import { SttAdmission } from "../../src/stt-admission";

export { SttAdmission };

export default {
  fetch(request: Request, env: { STT_ADMISSION: DurableObjectNamespace }) {
    return env.STT_ADMISSION.getByName("test").fetch(request);
  },
};
