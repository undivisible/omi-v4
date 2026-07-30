use base64::Engine as _;
use serde_json::{json, Value};
use worker::wasm_bindgen::{JsCast, JsValue};
use worker::wasm_bindgen_futures::JsFuture;
use worker::{
    js_sys, Env, Fetch, Headers, Method, Request, RequestInit, Response, Result, RouteContext,
    Router,
};

use crate::crypto_util::sha256_hex;
use crate::document_search::{
    document_name, image_mime, search_query, tenant_folder, MAX_DOCUMENT_BYTES, MAX_IMAGE_BYTES,
};
use crate::glue::{authenticate, error_json, AuthOutcome};
use crate::worker_util::secret_or_var;

pub fn register(router: Router<'static, ()>) -> Router<'static, ()> {
    router
        .post_async("/v1/documents", handle_upload)
        .get_async("/v1/documents/search", handle_search)
        .post_async("/v1/images/embeddings", handle_image_embedding)
}

async fn handle_image_embedding(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let _auth = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let mime = req
        .headers()
        .get("content-type")?
        .as_deref()
        .and_then(|value| image_mime(Some(value)));
    let Some(mime) = mime else {
        return error_json("Image must be PNG or JPEG", 415);
    };
    if req
        .headers()
        .get("content-length")?
        .and_then(|value| value.parse::<usize>().ok())
        .is_some_and(|size| size > MAX_IMAGE_BYTES)
    {
        return error_json("Image exceeds 8 MB", 413);
    }
    let bytes = req.bytes().await?;
    if bytes.is_empty() || bytes.len() > MAX_IMAGE_BYTES {
        return error_json("Image must contain at most 8 MB", 413);
    }
    let Some(key) = secret_or_var(&ctx.env, "GEMINI_API_KEY") else {
        return error_json("Image embeddings unavailable", 503);
    };
    let body = json!({
        "content": {
            "parts": [{
                "inline_data": {
                    "mime_type": mime,
                    "data": base64::engine::general_purpose::STANDARD.encode(bytes)
                }
            }]
        },
        "output_dimensionality": 768
    });
    let mut init = RequestInit::new();
    init.with_method(Method::Post);
    let headers = Headers::new();
    headers.set("content-type", "application/json")?;
    headers.set("x-goog-api-key", &key)?;
    init.with_headers(headers);
    init.with_body(Some(JsValue::from_str(&body.to_string())));
    let request = Request::new_with_init(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-2:embedContent",
        &init,
    )?;
    let mut response = Fetch::Request(request).send().await?;
    if response.status_code() >= 300 {
        return error_json("Image embedding failed", 502);
    }
    let result = response.json::<Value>().await?;
    let values = result
        .get("embedding")
        .and_then(|value| value.get("values"))
        .and_then(Value::as_array)
        .filter(|values| values.len() == 768);
    match values {
        Some(values) => Response::from_json(&json!({
            "model": "gemini-embedding-2",
            "dimensions": 768,
            "embedding": values
        })),
        None => error_json("Invalid image embedding response", 502),
    }
}

struct AiSearch(JsValue);

impl AiSearch {
    fn from_env(env: &Env) -> Option<Self> {
        let binding =
            js_sys::Reflect::get(env.as_ref(), &JsValue::from_str("DOCUMENT_SEARCH")).ok()?;
        (!binding.is_null() && !binding.is_undefined()).then_some(Self(binding))
    }

    async fn call(
        receiver: &JsValue,
        method: &str,
        args: &js_sys::Array,
    ) -> std::result::Result<JsValue, JsValue> {
        let function = js_sys::Reflect::get(receiver, &JsValue::from_str(method))?
            .dyn_into::<js_sys::Function>()?;
        let promise = function
            .apply(receiver, args)?
            .dyn_into::<js_sys::Promise>()?;
        JsFuture::from(promise).await
    }

    async fn upload(&self, name: &str, bytes: &[u8]) -> std::result::Result<Value, JsValue> {
        let items = js_sys::Reflect::get(&self.0, &JsValue::from_str("items"))?;
        let data = js_sys::Uint8Array::from(bytes).buffer();
        let args = js_sys::Array::of2(&JsValue::from_str(name), &data);
        let result = Self::call(&items, "upload", &args).await?;
        serde_wasm_bindgen::from_value(result).map_err(JsValue::from)
    }

    async fn search(&self, query: &str, folder: &str) -> std::result::Result<Value, JsValue> {
        let upper = format!("{folder}0");
        let payload = json!({
            "messages": [{ "role": "user", "content": query }],
            "ai_search_options": {
                "retrieval": {
                    "filters": {
                        "folder": { "$gte": folder, "$lt": upper }
                    }
                }
            }
        });
        let value = serde_wasm_bindgen::to_value(&payload).map_err(JsValue::from)?;
        let result = Self::call(&self.0, "search", &js_sys::Array::of1(&value)).await?;
        serde_wasm_bindgen::from_value(result).map_err(JsValue::from)
    }
}

async fn handle_upload(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let name = req
        .headers()
        .get("x-file-name")?
        .and_then(|value| document_name(&value));
    let Some(name) = name else {
        return error_json("A valid x-file-name header is required", 400);
    };
    if req
        .headers()
        .get("content-length")?
        .and_then(|value| value.parse::<usize>().ok())
        .is_some_and(|size| size > MAX_DOCUMENT_BYTES)
    {
        return error_json("Document exceeds 4 MB", 413);
    }
    let bytes = req.bytes().await?;
    if bytes.is_empty() || bytes.len() > MAX_DOCUMENT_BYTES {
        return error_json("Document must contain at most 4 MB", 413);
    }
    let Some(search) = AiSearch::from_env(&ctx.env) else {
        return error_json("Document search unavailable", 503);
    };
    let folder = tenant_folder(&sha256_hex(&auth.uid));
    match search.upload(&format!("{folder}{name}"), &bytes).await {
        Ok(item) => Ok(Response::from_json(&json!({ "item": item }))?.with_status(202)),
        Err(_) => error_json("Document upload failed", 502),
    }
}

async fn handle_search(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let query = req
        .url()?
        .query_pairs()
        .find_map(|(key, value)| (key == "q").then(|| value.into_owned()))
        .and_then(|value| search_query(&value));
    let Some(query) = query else {
        return error_json("A valid q parameter is required", 400);
    };
    let Some(search) = AiSearch::from_env(&ctx.env) else {
        return error_json("Document search unavailable", 503);
    };
    let folder = tenant_folder(&sha256_hex(&auth.uid));
    match search.search(&query, &folder).await {
        Ok(results) => Response::from_json(&results),
        Err(_) => error_json("Document search failed", 502),
    }
}
