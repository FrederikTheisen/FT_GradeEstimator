// FitBasedAltitudeFilter.mc
// Smooths altitude data using previous linear fit, compensates for spikes/hangs
// Usage: create an instance, call filter(altitude, predicted) for each sample

import Toybox.Lang;

class FitBasedAltitudeFilter {
    // Threshold for spike detection (meters)
    static var spikeThreshold = 3.0;
    // Smoothing factor for blending (0.0 = only predicted, 1.0 = only measured)
    static var blendAlpha = 0.5;
    
    // Previous filtered value
    private var lastFiltered = null;

    function filter(measured as Float, predicted as Float) as Float {
        var filtered = measured;
        var diff = measured - predicted;
        if (diff.abs() > spikeThreshold) {
            // Detected spike/hang, blend with predicted value
            filtered = blendAlpha * measured + (1.0 - blendAlpha) * predicted;
        }
        // Optionally, you can add more logic to handle consecutive spikes/hangs
        lastFiltered = filtered;
        return filtered;
    }

    function reset() {
        lastFiltered = null;
    }
}
