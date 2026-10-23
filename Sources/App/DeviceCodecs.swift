import CoreMedia
import VideoToolbox

/// Which video codecs this device decodes in hardware, in Twitch's `supported_codecs` format.
enum DeviceCodecs {
  static let hevc: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
  /// 'av01' (kCMVideoCodecType_AV1 isn't in the iOS 16 SDK). iPhone 15 Pro and later.
  static let av1: Bool = VTIsHardwareDecodeSupported(CMVideoCodecType(0x6176_3031))

  /// e.g. "h265,av1,h264". Twitch only lists 1440p (Enhanced Broadcasting) renditions when the
  /// request says the player can decode HEVC or AV1. HEVC first: more players handle it.
  static var enhanced: String {
    var codecs: [String] = []
    if hevc { codecs.append("h265") }
    if av1 { codecs.append("av1") }
    codecs.append("h264")
    return codecs.joined(separator: ",")
  }

  /// What the Settings screen shows.
  static var summary: String {
    switch (hevc, av1) {
    case (true, true): return "AV1 + HEVC"
    case (true, false): return "HEVC"
    case (false, true): return "AV1"
    case (false, false): return "H.264 only"
    }
  }

  /// The next, more conservative codec list to try after `codecs` failed to play.
  static func fallback(after codecs: String) -> String? {
    let list = codecs.split(separator: ",").map(String.init)
    guard list.count > 1 else { return nil }
    return list.dropFirst().joined(separator: ",")
  }
}
