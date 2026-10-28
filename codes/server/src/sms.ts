import { createHmac, randomUUID } from "node:crypto";
import { AuthError } from "./domain.ts";

export interface SmsSender {
  send(phone: string, code: string): Promise<void>;
}

export type FetchLike = (input: string | URL, init?: RequestInit) => Promise<Response>;

export interface SmsConfig {
  provider: string;
  httpUrl: string;
  httpToken: string;
  aliyunAccessKeyId: string;
  aliyunAccessKeySecret: string;
  aliyunSignName: string;
  aliyunTemplateCode: string;
}

export function createSmsSender(
  config: SmsConfig,
  fetchImpl: FetchLike,
  clock: { now?: () => Date; nonce?: () => string } = {},
): SmsSender | null {
  const provider = config.provider.trim().toLowerCase();
  if (!provider) return null;
  if (provider === "http") {
    if (!config.httpUrl) return failing("SMS_HTTP_URL is required when SMS_PROVIDER=http");
    return {
      async send(phone, code) {
        const headers: Record<string, string> = { "content-type": "application/json" };
        if (config.httpToken) headers.authorization = `Bearer ${config.httpToken}`;
        const response = await fetchImpl(config.httpUrl, {
          method: "POST",
          redirect: "error",
          headers,
          body: JSON.stringify({
            phone,
            code,
            signName: config.aliyunSignName || undefined,
            templateCode: config.aliyunTemplateCode || undefined,
          }),
        });
        if (!response.ok) {
          throw new AuthError("sms_failed", `SMS provider rejected the message (${response.status})`);
        }
      },
    };
  }
  if (provider === "aliyun") {
    if (!config.aliyunAccessKeyId || !config.aliyunAccessKeySecret || !config.aliyunSignName || !config.aliyunTemplateCode) {
      return failing(
        "Aliyun SMS needs ALIYUN_SMS_ACCESS_KEY_ID, ALIYUN_SMS_ACCESS_KEY_SECRET, ALIYUN_SMS_SIGN_NAME, and ALIYUN_SMS_TEMPLATE_CODE",
      );
    }
    return createAliyunSender({
      accessKeyId: config.aliyunAccessKeyId,
      accessKeySecret: config.aliyunAccessKeySecret,
      signName: config.aliyunSignName,
      templateCode: config.aliyunTemplateCode,
      fetchImpl,
      now: clock.now ?? (() => new Date()),
      nonce: clock.nonce ?? (() => randomUUID()),
    });
  }
  return failing(`Unknown SMS_PROVIDER "${config.provider}". Use http or aliyun.`);
}

function failing(message: string): SmsSender {
  return {
    async send() {
      throw new AuthError("sms_not_configured", message);
    },
  };
}

export function createAliyunSender(options: {
  accessKeyId: string;
  accessKeySecret: string;
  signName: string;
  templateCode: string;
  fetchImpl: FetchLike;
  now: () => Date;
  nonce: () => string;
}): SmsSender {
  return {
    async send(phone, code) {
      const params: Record<string, string> = {
        AccessKeyId: options.accessKeyId,
        Action: "SendSms",
        Format: "JSON",
        PhoneNumbers: phone,
        RegionId: "cn-hangzhou",
        SignName: options.signName,
        SignatureMethod: "HMAC-SHA1",
        SignatureNonce: options.nonce(),
        SignatureVersion: "1.0",
        TemplateCode: options.templateCode,
        TemplateParam: JSON.stringify({ code }),
        Timestamp: options.now().toISOString().replace(/\.\d{3}Z$/, "Z"),
        Version: "2017-05-25",
      };
      params.Signature = aliyunSign(params, options.accessKeySecret);
      const body = new URLSearchParams(params).toString();
      const response = await options.fetchImpl("https://dysmsapi.aliyuncs.com/", {
        method: "POST",
        redirect: "error",
        headers: { "content-type": "application/x-www-form-urlencoded; charset=UTF-8" },
        body,
      });
      const payload = (await response.json().catch(() => ({}))) as { Code?: string; Message?: string };
      if (!response.ok || payload.Code !== "OK") {
        throw new AuthError("sms_failed", "Aliyun SMS rejected the message");
      }
    },
  };
}

export function aliyunSign(params: Record<string, string>, secret: string): string {
  const canonical = Object.keys(params)
    .filter((key) => key !== "Signature")
    .sort()
    .map((key) => `${aliyunEncode(key)}=${aliyunEncode(params[key] ?? "")}`)
    .join("&");
  const stringToSign = `POST&${aliyunEncode("/")}&${aliyunEncode(canonical)}`;
  return createHmac("sha1", `${secret}&`).update(stringToSign).digest("base64");
}

function aliyunEncode(value: string): string {
  return encodeURIComponent(value)
    .replace(/!/g, "%21")
    .replace(/'/g, "%27")
    .replace(/\(/g, "%28")
    .replace(/\)/g, "%29")
    .replace(/\*/g, "%2A");
}
