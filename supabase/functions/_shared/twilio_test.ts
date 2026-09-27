import { assertEquals, assertRejects } from "@std/assert";
import { UpstreamError } from "./errors.ts";
import { FakeFetch, jsonResponse } from "./testing/fake_fetch.ts";
import {
  basicAuth,
  classifyOptKeyword,
  computeTwilioSignature,
  emptyTwiml,
  sendSms,
  TwilioError,
  twilioSignaturePayload,
  twilioUrlVariants,
  validateTwilioSignature,
} from "./twilio.ts";

// Worked example from Twilio's "Validating signatures" docs.
const DOC_TOKEN = "12345";
const DOC_URL = "https://mycompany.com/myapp.php?foo=1&bar=2";
const DOC_PARAMS = {
  CallSid: "CA1234567890ABCDE",
  Caller: "+12349013030",
  Digits: "1234",
  From: "+12349013030",
  To: "+18005551212",
};
const DOC_SIGNATURE = "0/KCTR6DLpKmkAf8muzZqo1nDgQ=";

// Vector from Twilio's reference library (twilio-node webhooks spec).
const LIB_PARAMS = {
  CallSid: "CA1234567890ABCDE",
  Caller: "+14158675309",
  Digits: "1234",
  From: "+14158675309",
  To: "+18005551212",
};
const LIB_SIGNATURE = "RSOYDt4T1cUTdK1PDd93/VVr8B8=";

const CREDS = { accountSid: "AC00000000000000000000000000000000", authToken: "tok" };
const MESSAGES_URL =
  "https://api.twilio.com/2010-04-01/Accounts/AC00000000000000000000000000000000/Messages.json";

Deno.test("twilio signature: official docs example vector", async () => {
  assertEquals(
    twilioSignaturePayload(DOC_URL, DOC_PARAMS),
    "https://mycompany.com/myapp.php?foo=1&bar=2CallSidCA1234567890ABCDECaller+12349013030Digits1234From+12349013030To+18005551212",
  );
  assertEquals(await computeTwilioSignature(DOC_TOKEN, DOC_URL, DOC_PARAMS), DOC_SIGNATURE);
  assertEquals(await validateTwilioSignature(DOC_TOKEN, DOC_SIGNATURE, DOC_URL, DOC_PARAMS), true);
});

Deno.test("twilio signature: reference-library vector, param order irrelevant", async () => {
  const shuffled = new URLSearchParams([
    ["To", LIB_PARAMS.To],
    ["Digits", LIB_PARAMS.Digits],
    ["From", LIB_PARAMS.From],
    ["CallSid", LIB_PARAMS.CallSid],
    ["Caller", LIB_PARAMS.Caller],
  ]);
  assertEquals(await computeTwilioSignature(DOC_TOKEN, DOC_URL, shuffled), LIB_SIGNATURE);
});

Deno.test("twilio signature: tampering, wrong token, wrong URL and missing header fail", async () => {
  assertEquals(
    await validateTwilioSignature(DOC_TOKEN, DOC_SIGNATURE, DOC_URL, {
      ...DOC_PARAMS,
      Digits: "9999",
    }),
    false,
  );
  assertEquals(await validateTwilioSignature("54321", DOC_SIGNATURE, DOC_URL, DOC_PARAMS), false);
  assertEquals(
    await validateTwilioSignature(
      DOC_TOKEN,
      DOC_SIGNATURE,
      "https://mycompany.com/myapp.php",
      DOC_PARAMS,
    ),
    false,
  );
  assertEquals(await validateTwilioSignature(DOC_TOKEN, null, DOC_URL, DOC_PARAMS), false);
  assertEquals(await validateTwilioSignature(DOC_TOKEN, "", DOC_URL, DOC_PARAMS), false);
  assertEquals(
    await validateTwilioSignature(DOC_TOKEN, DOC_SIGNATURE.slice(0, -1), DOC_URL, DOC_PARAMS),
    false,
  );
});

Deno.test("twilio signature: URLs with/without the default port both validate", async () => {
  const signedWithPort = await computeTwilioSignature(
    DOC_TOKEN,
    "https://mycompany.com:443/myapp.php?foo=1&bar=2",
    DOC_PARAMS,
  );
  assertEquals(await validateTwilioSignature(DOC_TOKEN, signedWithPort, DOC_URL, DOC_PARAMS), true);
  assertEquals(
    await validateTwilioSignature(
      DOC_TOKEN,
      DOC_SIGNATURE,
      "https://mycompany.com:443/myapp.php?foo=1&bar=2",
      DOC_PARAMS,
    ),
    true,
  );
  assertEquals(twilioUrlVariants("https://a.example.com/x?y=1"), [
    "https://a.example.com/x?y=1",
    "https://a.example.com:443/x?y=1",
  ]);
  assertEquals(twilioUrlVariants("not a url"), ["not a url"]);
});

Deno.test("twilio signature: repeated params are appended in sorted value order", () => {
  const params = new URLSearchParams([["MediaUrl", "b"], ["Body", "x"], ["MediaUrl", "a"]]);
  assertEquals(twilioSignaturePayload("https://h/p", params), "https://h/pBodyxMediaUrlaMediaUrlb");
  assertEquals(
    twilioSignaturePayload("https://h/p", { MediaUrl: ["b", "a"], Body: "x" }),
    "https://h/pBodyxMediaUrlaMediaUrlb",
  );
});

Deno.test("twilio sendSms: request shape (form fields, basic auth, endpoint)", async () => {
  const http = new FakeFetch();
  http.on("POST", MESSAGES_URL, () => jsonResponse({ sid: "SM123", status: "queued" }, 201));
  const sent = await sendSms(
    CREDS,
    {
      to: "+12055550123",
      from: "+12055550100",
      body: "Your appointment is confirmed.",
      statusCallback:
        "https://fake-project.supabase.co/functions/v1/messaging?action=twilio_status",
    },
    http.fetch,
  );
  assertEquals(sent, { sid: "SM123", status: "queued" });
  const call = http.calls[0];
  assertEquals(call?.headers.get("authorization"), basicAuth(CREDS.accountSid, CREDS.authToken));
  assertEquals(call?.headers.get("authorization"), `Basic ${btoa(`${CREDS.accountSid}:tok`)}`);
  assertEquals(call?.headers.get("content-type"), "application/x-www-form-urlencoded");
  assertEquals(Object.fromEntries(call?.form ?? []), {
    To: "+12055550123",
    From: "+12055550100",
    Body: "Your appointment is confirmed.",
    StatusCallback: "https://fake-project.supabase.co/functions/v1/messaging?action=twilio_status",
  });
});

Deno.test("twilio sendSms: messaging service sender uses MessagingServiceSid", async () => {
  const http = new FakeFetch();
  http.on("POST", MESSAGES_URL, () => jsonResponse({ sid: "SM1", status: "accepted" }, 201));
  await sendSms(
    CREDS,
    { to: "+12055550123", from: `MG${"a".repeat(32)}`, body: "hi" },
    http.fetch,
  );
  assertEquals(http.calls[0]?.form.get("MessagingServiceSid"), `MG${"a".repeat(32)}`);
  assertEquals(http.calls[0]?.form.has("From"), false);
});

Deno.test("twilio sendSms: API errors become TwilioError with the provider code", async () => {
  const http = new FakeFetch();
  http.on(
    "POST",
    MESSAGES_URL,
    () =>
      jsonResponse({
        code: 21610,
        message: "Attempt to send to unsubscribed recipient",
        status: 400,
      }, 400),
  );
  const err = await assertRejects(
    () => sendSms(CREDS, { to: "+12055550123", from: "+12055550100", body: "hi" }, http.fetch),
    TwilioError,
  );
  assertEquals(err.providerCode, "21610");
  assertEquals(err.httpStatus, 400);
  assertEquals(err instanceof UpstreamError, true);
});

Deno.test("twilio sendSms: network failures and bad input", async () => {
  const http = new FakeFetch(); // no routes -> fetch rejects
  await assertRejects(
    () => sendSms(CREDS, { to: "+12055550123", from: "+12055550100", body: "hi" }, http.fetch),
    TwilioError,
  );
  await assertRejects(
    () => sendSms(CREDS, { to: "2055550123", from: "+12055550100", body: "hi" }, http.fetch),
    TypeError,
  );
  await assertRejects(
    () => sendSms(CREDS, { to: "+12055550123", from: "shop", body: "hi" }, http.fetch),
    TypeError,
  );
  await assertRejects(
    () => sendSms(CREDS, { to: "+12055550123", from: "+12055550100", body: "  " }, http.fetch),
    TypeError,
  );
  assertEquals(http.calls.length, 1);
});

Deno.test("twilio: opt-out / opt-in / help keywords", () => {
  for (
    const word of [
      "STOP",
      "stop",
      " Stop. ",
      "unsubscribe",
      "Cancel",
      "end",
      "QUIT",
      "stopall",
      "optout",
      "revoke",
    ]
  ) {
    assertEquals(classifyOptKeyword(word), "opt_out", word);
  }
  for (const word of ["START", "yes", "Unstop"]) {
    assertEquals(classifyOptKeyword(word), "opt_in", word);
  }
  for (const word of ["help", "INFO"]) assertEquals(classifyOptKeyword(word), "help", word);
  for (const text of ["stop by at 5?", "Yes please come at 3", "", "thanks"]) {
    assertEquals(classifyOptKeyword(text), null, text);
  }
});

Deno.test("twilio: empty TwiML acknowledgement", async () => {
  const res = emptyTwiml();
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("content-type"), "text/xml; charset=utf-8");
  assertEquals(await res.text(), '<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
});
