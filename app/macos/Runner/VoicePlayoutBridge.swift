import AVFoundation
import FlutterMacOS

final class VoicePlayoutQueue {
  private(set) var queuedFrames = 0
  let sampleRateHz: Double

  init(sampleRateHz: Double) {
    self.sampleRateHz = sampleRateHz
  }

  var queuedMs: Int {
    guard sampleRateHz > 0 else { return 0 }
    return Int((Double(queuedFrames) * 1000 / sampleRateHz).rounded())
  }

  func scheduled(frames: Int) {
    queuedFrames += frames
  }

  func completed(frames: Int) {
    queuedFrames = max(0, queuedFrames - frames)
  }
}

final class VoicePlayoutBridge: NSObject {
  private let channel: FlutterMethodChannel
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var format: AVAudioFormat?
  private var queue: VoicePlayoutQueue?
  private var generation = 0

  init(binaryMessenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "omi/voice_playout", binaryMessenger: binaryMessenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        return result(
          FlutterError(code: "playout_unavailable", message: nil, details: nil))
      }
      switch call.method {
      case "start":
        let arguments = call.arguments as? [String: Any]
        guard let sampleRateHz = arguments?["sampleRateHz"] as? Int, sampleRateHz > 0 else {
          return result(
            FlutterError(code: "playout_invalid_rate", message: nil, details: nil))
        }
        do {
          try self.start(sampleRateHz: Double(sampleRateHz))
          result(nil)
        } catch {
          self.stop()
          result(
            FlutterError(
              code: "playout_start_failed",
              message: error.localizedDescription,
              details: nil))
        }
      case "feed":
        guard
          let data = (call.arguments as? [String: Any])?["bytes"]
            as? FlutterStandardTypedData
        else {
          return result(
            FlutterError(code: "playout_invalid_bytes", message: nil, details: nil))
        }
        guard let player = self.player, let format = self.format, let queue = self.queue
        else {
          return result(
            FlutterError(code: "playout_not_started", message: nil, details: nil))
        }
        result(self.feed(data.data, player: player, format: format, queue: queue))
      case "flush":
        self.flush()
        result(nil)
      case "stop":
        self.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func start(sampleRateHz: Double) throws {
    stop()
    // AVAudioPlayerNode only accepts float PCM; int16 chunks are converted in feed.
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRateHz,
        channels: 1,
        interleaved: false)
    else {
      throw NSError(
        domain: "omi.voice_playout", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Unsupported sample rate."])
    }
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    try engine.start()
    player.play()
    self.engine = engine
    self.player = player
    self.format = format
    self.queue = VoicePlayoutQueue(sampleRateHz: sampleRateHz)
  }

  private func feed(
    _ data: Data,
    player: AVAudioPlayerNode,
    format: AVAudioFormat,
    queue: VoicePlayoutQueue
  ) -> Int {
    let frames = data.count / MemoryLayout<Int16>.size
    guard
      frames > 0,
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
      let samples = buffer.floatChannelData?[0]
    else {
      return queue.queuedMs
    }
    buffer.frameLength = AVAudioFrameCount(frames)
    data.withUnsafeBytes { raw in
      let int16 = raw.bindMemory(to: Int16.self)
      for index in 0..<frames {
        samples[index] = Float(Int16(littleEndian: int16[index])) / 32768
      }
    }
    queue.scheduled(frames: frames)
    let generation = self.generation
    player.scheduleBuffer(buffer) { [weak self] in
      DispatchQueue.main.async {
        guard let self, self.generation == generation else { return }
        self.queue?.completed(frames: frames)
      }
    }
    return queue.queuedMs
  }

  private func flush() {
    generation += 1
    guard let player = player, let sampleRateHz = queue?.sampleRateHz else { return }
    queue = VoicePlayoutQueue(sampleRateHz: sampleRateHz)
    player.stop()
    player.play()
  }

  private func stop() {
    generation += 1
    player?.stop()
    engine?.stop()
    player = nil
    engine = nil
    format = nil
    queue = nil
  }
}
