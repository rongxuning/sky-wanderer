import type { SmsConfig } from "./sms.ts";

export interface AppConfig {
  demo: boolean;
  databaseUrl: string;
  port: number;
  dataFile: string;
  apiHost: string;
  codePepper: string;
  sessionTtlDays: number;
  sms: SmsConfig;
  wechatAppId: string;
  wechatAppSecret: string;
  googleClientIds: string[];
  googleClientSecret: string;
  googleRedirectUris: string[];
}

export function loadConfig(env: NodeJS.ProcessEnv): AppConfig {
  const demo = env.AUTH_DEMO === "1";
  const databaseUrl = env.DATABASE_URL?.trim() ?? "";
  if (!demo && !databaseUrl) {
    throw new Error("DATABASE_URL is required unless AUTH_DEMO=1");
  }
  const apiHost = env.SKY_API_HOST?.trim() || "api.sky-wanderer.online";
  const googleRedirectRaw = env.GOOGLE_REDIRECT_URIS?.trim() ?? "";
  const googleRedirectUris = googleRedirectRaw
    ? splitList(googleRedirectRaw)
    : [`https://${apiHost}/v1/auth/google/callback`];
  const days = Number(env.SESSION_TTL_DAYS);
  return {
    demo,
    databaseUrl,
    port: Number(env.PORT || "8787"),
    dataFile: env.DATA_FILE?.trim() || "data/auth-store.json",
    apiHost,
    codePepper: env.AUTH_CODE_PEPPER?.trim() ?? "",
    sessionTtlDays: Number.isFinite(days) && days > 0 ? days : 30,
    sms: {
      provider: env.SMS_PROVIDER?.trim() ?? "",
      httpUrl: env.SMS_HTTP_URL?.trim() ?? "",
      httpToken: env.SMS_HTTP_TOKEN?.trim() ?? "",
      aliyunAccessKeyId: env.ALIYUN_SMS_ACCESS_KEY_ID?.trim() ?? "",
      aliyunAccessKeySecret: env.ALIYUN_SMS_ACCESS_KEY_SECRET?.trim() ?? "",
      aliyunSignName: env.ALIYUN_SMS_SIGN_NAME?.trim() ?? "",
      aliyunTemplateCode: env.ALIYUN_SMS_TEMPLATE_CODE?.trim() ?? "",
    },
    wechatAppId: env.WECHAT_APP_ID?.trim() ?? "",
    wechatAppSecret: env.WECHAT_APP_SECRET?.trim() ?? "",
    googleClientIds: splitList(env.GOOGLE_CLIENT_IDS ?? ""),
    googleClientSecret: env.GOOGLE_CLIENT_SECRET?.trim() ?? "",
    googleRedirectUris,
  };
}

function splitList(value: string): string[] {
  return value
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}
