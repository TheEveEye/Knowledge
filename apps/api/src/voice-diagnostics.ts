import { appendFile, mkdir, readdir, readFile, stat, unlink } from "node:fs/promises";
import { join, resolve } from "node:path";
import { z } from "zod";
import { DomainError } from "@knowledge/backend";

const number = z.number().finite().min(-1_000_000).max(1_000_000_000).nullable().optional();
const flag = z.boolean().nullable().optional();
const knownString = (values: string[]) => z.string().max(100).transform(value => values.includes(value) ? value : "other");
const sample = z.object({
  transport: z.enum(["native-webrtc", "webkit"]).optional(),
  audioDeviceRunning: flag,
  speakerEchoGuard: flag, automaticInterruption: flag,
  phase: z.enum(["capture", "connected", "playback_sample", "speech_started", "speech_confirmed", "playback_started", "route_changed", "microphone_gate"]),
  elapsedMs: number, echoCancellationRequested: flag, noiseSuppressionRequested: flag, autoGainControlRequested: flag,
  echoCancellationSupported: flag, noiseSuppressionSupported: flag, autoGainControlSupported: flag,
  echoCancellation: z.union([z.boolean(), z.enum(["all", "remote-only"])]).nullable().optional(),
  noiseSuppression: flag, autoGainControl: flag, sampleRate: number, channelCount: number, captureLatency: number,
  microphoneEnabled: flag, microphoneMuted: flag, tutorPlaying: flag, outputMuted: flag, paused: flag, userMuted: flag, serverListening: flag,
  statsAvailable: flag, statsFailed: flag, diagnosticsFailed: flag, microphoneLevel: number, remoteLevel: number,
  echoReturnLoss: number, echoReturnLossEnhancement: number, nativeSampleRate: number, ioBufferDuration: number, inputLatency: number, outputLatency: number,
  category: knownString(["AVAudioSessionCategoryAmbient", "AVAudioSessionCategorySoloAmbient", "AVAudioSessionCategoryPlayback", "AVAudioSessionCategoryRecord", "AVAudioSessionCategoryPlayAndRecord", "AVAudioSessionCategoryMultiRoute"]).optional(),
  mode: knownString(["AVAudioSessionModeDefault", "AVAudioSessionModeVoiceChat", "AVAudioSessionModeVideoChat", "AVAudioSessionModeSpokenAudio", "AVAudioSessionModeMeasurement", "AVAudioSessionModeMoviePlayback", "AVAudioSessionModeVideoRecording", "AVAudioSessionModeVoicePrompt", "AVAudioSessionModeGameChat"]).optional(),
  inputPorts: z.array(knownString(["MicrophoneBuiltIn", "HeadsetMic", "BluetoothHFP", "BluetoothLE", "USBAudio", "LineIn", "Virtual"])).max(8).optional(),
  outputPorts: z.array(knownString(["Speaker", "Receiver", "Headphones", "BluetoothHFP", "BluetoothA2DPOutput", "BluetoothLE", "USBAudio", "AirPlay", "HDMI", "DisplayPort", "LineOut", "Virtual"])).max(8).optional(),
});
export const voiceDiagnosticBatch = z.strictObject({ batchID: z.uuid(), samples: z.array(sample).min(1).max(20) });
const filePattern = /^[a-f0-9-]{36}_[a-f0-9-]{36}_[a-f0-9-]{36}\.jsonl$/;
const retention = 7 * 86_400_000, maximumBytes = 2 * 1024 * 1024;

/** Technical measurements only; never accepts raw logs, speech or arbitrary attachments. */
export class VoiceDiagnostics {
  private root = resolve(process.env.SOURCE_DIRECTORY ?? ".data/sources", "voice-diagnostics");
  private writes = Promise.resolve();
  private pending = 0;
  private timer = setInterval(() => { void this.prune().catch(() => {}); }, 3_600_000);
  constructor() { this.timer.unref(); void this.prune().catch(() => {}); }
  close() { clearInterval(this.timer); return this.writes; }
  private name(userID: string, sessionID: string, voiceID: string) {
    return [userID, sessionID, voiceID].map(id => z.uuid().parse(id).toLowerCase()).join("_") + ".jsonl";
  }
  private async prune() {
    await mkdir(this.root, { recursive: true, mode: 0o700 });
    for (const name of await readdir(this.root)) {
      if (!filePattern.test(name)) continue;
      const path = join(this.root, name), info = await stat(path).catch(() => null);
      if (info && info.mtimeMs < Date.now() - retention) await unlink(path).catch(() => {});
    }
  }
  async list(userID: string) {
    const prefix = z.uuid().parse(userID).toLowerCase() + "_";
    await this.prune();
    const entries = [];
    for (const name of await readdir(this.root)) {
      if (!filePattern.test(name) || !name.startsWith(prefix)) continue;
      const info = await stat(join(this.root, name)).catch(() => null);
      if (!info) continue;
      const [, sessionID, voiceID] = name.slice(0, -6).split("_");
      entries.push({ sessionID, voiceID, bytes: info.size, updatedAt: info.mtime.toISOString() });
    }
    return entries.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  }
  async read(userID: string, sessionID: string, voiceID: string) {
    await this.prune();
    try { return await readFile(join(this.root, this.name(userID, sessionID, voiceID))); }
    catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") throw new DomainError("NOT_FOUND", "These diagnostics are unavailable or expired.", 404); throw error; }
  }
  append(userID: string, sessionID: string, voiceID: string, batch: z.infer<typeof voiceDiagnosticBatch>) {
    if (this.pending >= 4) return Promise.reject(new DomainError("DIAGNOSTIC_LIMIT", "Diagnostic upload is busy.", 429));
    this.pending++;
    const write = this.writes.then(async () => {
      const files = await this.list(userID), name = this.name(userID, sessionID, voiceID), path = join(this.root, name);
      const info = await stat(path).catch(() => null);
      if (!info && files.length >= 20) {
        const oldest = files.at(-1)!;
        await unlink(join(this.root, this.name(userID, oldest.sessionID!, oldest.voiceID!)));
      }
      if (info) {
        // Retries with an uncertain acknowledgement must not duplicate samples.
        if (info.size >= maximumBytes) throw new DomainError("DIAGNOSTIC_LIMIT", "Diagnostic file limit reached.", 429);
        if ((await readFile(path, "utf8")).includes('"batchID":"' + batch.batchID + '"')) return;
      }
      const data = JSON.stringify({ receivedAt: new Date().toISOString(), sessionID, voiceID, ...batch }) + "\n";
      if ((info?.size ?? 0) + Buffer.byteLength(data) > maximumBytes) throw new DomainError("DIAGNOSTIC_LIMIT", "Diagnostic file limit reached.", 429);
      await appendFile(path, data, { mode: 0o600 });
    }).finally(() => { this.pending--; });
    this.writes = write.catch(() => {});
    return write;
  }
}
