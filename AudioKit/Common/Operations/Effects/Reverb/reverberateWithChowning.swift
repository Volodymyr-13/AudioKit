//
//  reverberateWithChowning.swift
//  AudioKit For iOS
//
//  Autogenerated by scripts by Aurelius Prochazka. Do not edit directly.
//  Copyright © 2015 AudioKit. All rights reserved.
//

import Foundation

extension AKOperation {

    /// This is was built using the JC reverb implentation found in FAUST. According
    /// to the source code, the specifications for this implementation were found on
    /// an old SAIL DART backup tape.
    /// This class is derived from the CLM JCRev function, which is based on the use
    /// of networks of simple allpass and comb delay filters.  This class implements
    /// three series allpass units, followed by four parallel comb filters, and two
    /// decorrelation delay lines in parallel at the output.
    ///
    /// - returns: AKOperation
    /// - parameter input: Input audio signal
     ///
    public func reverberateWithChowning(
        ) -> AKOperation {
            return AKOperation("(\(self) jcrev)")
    }
}
