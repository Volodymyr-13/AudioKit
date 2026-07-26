// Copyright AudioKit. All Rights Reserved. Revision History at http://github.com/AudioKit/AudioKit/

import AVFoundation

extension AVAudioNode {
    var audioKitAudioUnit: AUAudioUnit {
        let selector = NSSelectorFromString("AUAudioUnit")
        guard responds(to: selector),
              let result = perform(selector),
              let audioUnit = result.takeUnretainedValue() as? AUAudioUnit else {
            fatalError("Expected AVAudioNode to provide an AUAudioUnit.")
        }
        return audioUnit
    }
}
