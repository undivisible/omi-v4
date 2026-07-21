import { AssistantAdmission } from "../../src/assistant-admission";

export { AssistantAdmission };

export default {
  fetch(
    request: Request,
    env: { ASSISTANT_ADMISSION: DurableObjectNamespace },
  ) {
    return env.ASSISTANT_ADMISSION.getByName("managed-ai-global").fetch(
      request,
    );
  },
};
