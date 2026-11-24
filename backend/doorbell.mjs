#!/usr/bin/env node
// Eufy doorbell bridge for the Omarchy shell.
//
// The shell service (Service.qml) owns this process and talks to it in JSON
// lines: commands arrive on stdin, events leave on stdout, logs go to stderr.
// Nothing here draws UI; the job is to say "ring" as early as possible.
//
// Events:   status · devices · ring · snapshot · live · live-ended
// Commands: login · captcha · code · logout · live · stop-live

import { execFile, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DATA_DIR = path.join(process.env.XDG_DATA_HOME || path.join(os.homedir(), ".local/share"), "omarchy-eufy-doorbell");
const RUNTIME_DIR = path.join(process.env.XDG_RUNTIME_DIR || os.tmpdir(), "omarchy-eufy-doorbell");
const ACCOUNT_FILE = path.join(DATA_DIR, "account.json");
const SESSION_FILE = path.join(DATA_DIR, "session.json");
const PUSH_FILE = path.join(DATA_DIR, "push.json");
const KEYRING = ["service", "omarchy-eufy-doorbell", "account"];

// A doorbell press can reach the SDK over push and P2P both; one ring is enough.
const RING_DEDUPE_MS = 8_000;
// Battery doorbells pay for every second of video. The overlay closes well before this.
const LIVE_MAX_MS = 90_000;
// The push thumbnail lands shortly after the press; look a few times, show each new one.
const SNAPSHOT_DELAYS_MS = [0, 700, 800, 1500, 2000];
const MAX_GOP_FRAMES = 300;

let sdk = null;
let eufy = null;
let account = readJson(ACCOUNT_FILE);
let names = new Map();
let lastRing = new Map();
let live = null;
let snapshotRun = 0;

function emit(event) {
  process.stdout.write(JSON.stringify(event) + "\n");
}

function setStatus(state, extra = {}) {
  emit({ type: "status", state, email: account?.email ?? "", ...extra });
}

function log(...parts) {
  console.error(...parts);
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function errorText(error) {
  return String(error?.message || error || "Unknown error").slice(0, 300);
}

// ---------------------------------------------------------------- keyring

// The password lives in the desktop keyring, so the SDK can log in again by
// itself when eufy expires the session. The session token is in DATA_DIR.
function secretTool(args, input = "") {
  return new Promise((resolve) => {
    const child = execFile("secret-tool", args, { timeout: 10_000 }, (error, stdout) => resolve(error ? null : stdout));
    child.stdin.end(input);
  });
}

async function savePassword(email, password) {
  return (await secretTool(["store", "--label", "eufy doorbell (Omarchy)", ...KEYRING, email], password)) !== null;
}

async function loadPassword(email) {
  return (await secretTool(["lookup", ...KEYRING, email])) ?? "";
}

function forgetPassword(email) {
  return secretTool(["clear", ...KEYRING, email]);
}

// ---------------------------------------------------------------- runtime

function nodeIsRecentEnough() {
  const [major, minor] = process.versions.node.split(".").map(Number);
  return major > 24 || (major === 24 && minor >= 5);
}

// scripts/install-backend.sh installs the SDK into DATA_DIR from this plugin's
// lockfile. A plugin update that bumps the lockfile asks for a reinstall.
function runtimeInstalled() {
  try {
    const installed = fs.readFileSync(path.join(DATA_DIR, "package-lock.json"), "utf8");
    const wanted = fs.readFileSync(path.join(HERE, "package-lock.json"), "utf8");
    return installed === wanted && fs.existsSync(path.join(DATA_DIR, "node_modules/@mega-yfue/eufy-sdk/package.json"));
  } catch {
    return false;
  }
}

async function loadSdk() {
  const require = createRequire(path.join(DATA_DIR, "package.json"));
  return import(pathToFileURL(require.resolve("@mega-yfue/eufy-sdk")).href);
}

// ---------------------------------------------------------------- eufy client

function createClient(email, password, countryCode) {
  const client = new sdk.EufyMega({
    email,
    password,
    countryCode,
    store: new sdk.FileSessionStore(SESSION_FILE),
    pushStore: new sdk.FileFcmStore(PUSH_FILE),
    // Doorbell presses arrive over push; the slow cloud poll adds nothing here.
    pollMs: 0,
    logger: {
      debug() {},
      info() {},
      warn: (message) => log("eufy warn:", message),
      error: (message) => log("eufy error:", message),
    },
  });
  client.on("doorbellPress", (event) => ring(event.deviceSn));
  client.on("sessionExpired", (error) => relogin(error?.retryAfterMs ?? 0));
  client.on("error", (error) => log("eufy:", errorText(error)));
  return client;
}

// Exiting non-zero makes the service start us again with a growing delay,
// which is the retry for everything that is not the user's to fix.
function retryLater(context, error) {
  log(`${context}:`, errorText(error));
  setStatus("error", { message: errorText(error) });
  process.exit(1);
}

async function login(step) {
  setStatus("logging-in");
  let result;
  try {
    result = await step();
  } catch (error) {
    // eufy answered with an error code (wrong password, unknown account): the
    // user has to act. Anything else, like no network yet after boot, passes.
    if (typeof error?.code !== "number") return retryLater("login", error);
    log("login refused:", errorText(error));
    return setStatus("logged-out", { message: errorText(error) });
  }

  if (result.status === "captcha") return setStatus("captcha", { image: result.image, retry: result.retry === true });
  if (result.status === "2fa") return setStatus("2fa", { method: result.method || "email" });
  try {
    await connect();
  } catch (error) {
    retryLater("connect", error);
  }
}

async function connect() {
  setStatus("connecting");
  const devices = await eufy.getDevices();
  names = new Map(devices.map((device) => [device.sn, device.name || device.sn]));

  const cameras = devices.filter((device) => device.deviceClass === "camera");
  const doorbells = [];
  for (const camera of cameras) {
    const device = await eufy.getDevice(camera.sn);
    if (typeof device.doorbell === "function") doorbells.push(camera);
  }
  // A doorbell the SDK cannot tell from a camera still rings; list the cameras then.
  const listed = doorbells.length > 0 ? doorbells : cameras;
  emit({ type: "devices", doorbells: listed.map((device) => ({ sn: device.sn, name: names.get(device.sn) })) });

  const realtime = await eufy.waitForRealtime({ timeoutMs: 30_000 });
  if (realtime.push.ready === 0) {
    // Without push no press reaches us; let the service restart us with backoff.
    throw new Error("eufy push notifications did not start");
  }
  setStatus("ready");
}

async function relogin(waitMs) {
  log(`eufy session expired; logging in again in ${Math.round(waitMs / 1000)} s`);
  stopLive();
  await sleep(waitMs);
  await login(() => eufy.login());
}

async function start() {
  if (!nodeIsRecentEnough()) {
    setStatus("no-node", { message: `Node.js ${process.versions.node} is too old; eufy-sdk needs 24.5 or newer.` });
    process.exit(0);
  }
  if (!runtimeInstalled()) {
    setStatus("needs-install");
    process.exit(0);
  }
  sdk = await loadSdk();
  await startLiveServer();
  if (!account?.email) return setStatus("logged-out");

  eufy = createClient(account.email, await loadPassword(account.email), account.country);
  await login(() => eufy.login());
}

// ---------------------------------------------------------------- ring

function ring(sn) {
  const now = Date.now();
  if (now - (lastRing.get(sn) ?? 0) < RING_DEDUPE_MS) return;
  lastRing.set(sn, now);

  // First line out, before any network work: this is what puts the bell on screen.
  emit({ type: "ring", deviceSn: sn, name: names.get(sn) || "", at: now });
  showCamera(sn);
}

function showCamera(sn) {
  grabSnapshots(sn).catch((error) => log("snapshot:", errorText(error)));
  startLive(sn).catch((error) => {
    log("live:", errorText(error));
    stopLive();
  });
}

async function cameraFor(sn) {
  const device = await eufy.getDevice(sn);
  return device.camera?.();
}

async function grabSnapshots(sn) {
  const run = ++snapshotRun;
  const camera = await cameraFor(sn);
  if (!camera?.snapshotStored) return;

  let shown = null;
  for (const delay of SNAPSHOT_DELAYS_MS) {
    await sleep(delay);
    if (run !== snapshotRun) return;
    const jpeg = await camera.snapshotStored().catch(() => null);
    if (!jpeg || (shown && jpeg.equals(shown))) continue;
    shown = jpeg;
    emit({ type: "snapshot", deviceSn: sn, path: writeSnapshot(sn, jpeg) });
  }
}

function writeSnapshot(sn, jpeg) {
  fs.mkdirSync(RUNTIME_DIR, { recursive: true, mode: 0o700 });
  const file = path.join(RUNTIME_DIR, `${sn}-${Date.now()}.jpg`);
  fs.writeFileSync(file, jpeg, { mode: 0o600 });

  // Keep the newest few: the overlay and a "missed ring" notification point at them.
  const old = fs.readdirSync(RUNTIME_DIR).filter((name) => name.endsWith(".jpg")).sort((a, b) => {
    return fs.statSync(path.join(RUNTIME_DIR, b)).mtimeMs - fs.statSync(path.join(RUNTIME_DIR, a)).mtimeMs;
  });
  for (const name of old.slice(5)) fs.rmSync(path.join(RUNTIME_DIR, name), { force: true });
  return file;
}

// ---------------------------------------------------------------- live view

// One camera pull, served to the overlay as MPEG-TS on localhost. The SDK
// hands over Annex-B H.264/H.265 frames; ffmpeg only remuxes, never transcodes.
// Frames since the last keyframe are kept, so a player that connects late
// still starts on a picture right away.
let liveServer = null;

function startLiveServer() {
  liveServer = http.createServer((request, response) => {
    const session = live;
    if (!session?.codec || request.method !== "GET" || request.url !== `/live/${session.token}.ts`) {
      response.writeHead(404).end();
      return;
    }
    const ffmpeg = spawn("ffmpeg", [
      "-hide_banner", "-loglevel", "error",
      "-fflags", "nobuffer", "-use_wallclock_as_timestamps", "1",
      "-f", session.codec === "h265" ? "hevc" : "h264", "-i", "pipe:0",
      "-c:v", "copy", "-f", "mpegts", "-flush_packets", "1", "pipe:1",
    ], { stdio: ["pipe", "pipe", "inherit"] });
    ffmpeg.stdin.on("error", () => {});
    ffmpeg.on("error", (error) => log("ffmpeg:", errorText(error)));
    ffmpeg.on("exit", () => {
      session.viewers.delete(ffmpeg);
      response.end();
    });
    // SIGKILL: ffmpeg waiting on a quiet stdin ignores SIGTERM until the next frame, which never comes.
    request.on("close", () => ffmpeg.kill("SIGKILL"));

    response.writeHead(200, { "Content-Type": "video/mp2t", "Cache-Control": "no-store" });
    ffmpeg.stdout.pipe(response);
    for (const data of session.gop) ffmpeg.stdin.write(data);
    session.viewers.add(ffmpeg);
  });
  return new Promise((resolve) => liveServer.listen(0, "127.0.0.1", resolve));
}

async function startLive(sn) {
  if (live?.sn === sn) {
    if (live.codec) emitLive(live);
    return;
  }
  stopLive();
  const camera = await cameraFor(sn);
  if (!camera?.live) {
    emit({ type: "live-ended", deviceSn: sn });
    return;
  }

  const session = { sn, token: randomBytes(16).toString("hex"), codec: "", gop: [], viewers: new Set(), consumer: null };
  session.timer = setTimeout(() => stopLive(session), LIVE_MAX_MS);
  live = session;

  const consumer = await camera.live();
  if (live !== session) {
    consumer.stop();
    return;
  }
  session.consumer = consumer;
  consumer.on("video", (frame) => onFrame(session, frame));
  consumer.on("stop", () => stopLive(session));
  consumer.on("error", (error) => {
    log("live:", errorText(error));
    stopLive(session);
  });
}

function onFrame(session, frame) {
  if (frame.keyframe) session.gop = [];
  else if (session.gop.length === 0 || session.gop.length >= MAX_GOP_FRAMES) return;
  session.gop.push(frame.data);

  if (!session.codec) {
    session.codec = frame.codec;
    emitLive(session);
  }
  for (const viewer of session.viewers) viewer.stdin.write(frame.data);
}

function emitLive(session) {
  emit({ type: "live", deviceSn: session.sn, url: `http://127.0.0.1:${liveServer.address().port}/live/${session.token}.ts` });
}

function stopLive(session = live) {
  if (!session || live !== session) return;
  live = null;
  clearTimeout(session.timer);
  session.consumer?.stop();
  for (const viewer of session.viewers) viewer.kill("SIGKILL");
  emit({ type: "live-ended", deviceSn: session.sn });
}

// ---------------------------------------------------------------- commands

function validSn(sn) {
  return typeof sn === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(sn);
}

const commands = {
  async login({ email, password, country }) {
    email = String(email || "").trim().slice(0, 254);
    password = String(password || "").slice(0, 512);
    country = String(country || "").trim().toUpperCase();
    if (!email.includes("@") || !password || !/^[A-Z]{2}$/.test(country)) {
      return setStatus("logged-out", { message: "Fill in an email address, a password and a two-letter country code." });
    }
    stopLive();
    await eufy?.disconnect().catch(() => {});
    if (account?.email && account.email !== email) await forgetLogin();

    account = { email, country };
    fs.mkdirSync(DATA_DIR, { recursive: true, mode: 0o700 });
    fs.writeFileSync(ACCOUNT_FILE, JSON.stringify(account), { mode: 0o600 });
    if (!(await savePassword(email, password))) log("could not store the password in the keyring; it stays in memory");

    eufy = createClient(email, password, country);
    await login(() => eufy.login());
  },

  async captcha({ answer }) {
    if (eufy) await login(() => eufy.solveCaptcha(String(answer || "").trim()));
  },

  async code({ code }) {
    if (eufy) await login(() => eufy.submitVerifyCode(String(code || "").trim()));
  },

  async logout() {
    stopLive();
    await eufy?.logout().catch((error) => log("logout:", errorText(error)));
    eufy = null;
    await forgetLogin();
    account = null;
    emit({ type: "devices", doorbells: [] });
    setStatus("logged-out");
  },

  async live({ deviceSn }) {
    if (eufy && validSn(deviceSn)) showCamera(deviceSn);
    else emit({ type: "live-ended", deviceSn: String(deviceSn || "") });
  },

  async "stop-live"() {
    snapshotRun++;
    stopLive();
  },
};

async function forgetLogin() {
  if (account?.email) await forgetPassword(account.email);
  for (const file of [ACCOUNT_FILE, SESSION_FILE, PUSH_FILE]) fs.rmSync(file, { force: true });
}

// Commands run one at a time, in order: a 2FA code must not overtake its login.
let queue = Promise.resolve();
createInterface({ input: process.stdin }).on("line", (line) => {
  if (!line.trim()) return;
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return log("ignored a line that is not JSON");
  }
  const command = commands[message?.cmd];
  if (!command) return log("unknown command:", String(message?.cmd).slice(0, 40));
  queue = queue.then(() => command(message)).catch((error) => log(`${message.cmd}:`, errorText(error)));
});

async function shutdown() {
  stopLive();
  await eufy?.disconnect().catch(() => {});
  process.exit(0);
}

process.stdin.on("end", shutdown);
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
process.on("unhandledRejection", (error) => log("unhandled:", errorText(error)));

start().catch((error) => {
  log("fatal:", errorText(error));
  setStatus("error", { message: errorText(error) });
  process.exit(1);
});
