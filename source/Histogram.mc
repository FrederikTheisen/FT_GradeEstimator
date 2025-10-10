import Toybox.Lang;

class Histogram {
    const minBin = -25.0; // Minimum value for bins
    const maxBin = 25.0;  // Maximum value for bins
    const minQuality = 0.5; // Minimum quality to consider a data point
    
    private var bins = [];
    private var binSize as Float;
    private var numBins as Number;
    private var totalCount as Number = 0;

    public var computed as Boolean = false;
    public var computedSampledBinRange as Array = [0.0, 0.0];
    public var computedHistogramForRange as Array = [];

    public function shouldUpdate() as Boolean {
        if (totalCount < 100) { return true; }
        else if (totalCount < 500) { return (totalCount % 2 == 0); }
        else if (totalCount < 2000) { return (totalCount % 4 == 0); }
        else if (totalCount < 5000) { return (totalCount % 8 == 0); }
        else { return (totalCount % 16 == 0); }
    }

    function initialize(binSize as Float) {
        self.binSize = binSize;
        self.bins = [];
        for (var i = minBin; i < maxBin; i += binSize) { self.bins.add(0); }
        self.numBins = bins.size();
        self.totalCount = 0;
    }

    function addData(grade as Float, quality as Float) {
        if (quality < minQuality) {
            // Ignore low quality data
            return;
        }
        var binIndex = ((grade - self.minBin) / self.binSize).toNumber();
        if (binIndex >= 0 && binIndex < numBins) {
            self.bins[binIndex] += 1;
            self.totalCount += 1;
        }
        else if (binIndex < 0) {
            self.bins[0] += 1;
            self.totalCount += 1;
        }
        else if (binIndex >= numBins) {
            self.bins[self.numBins - 1] += 1;
            self.totalCount += 1;
        }
    }

    function getBinCount(binIndex as Number) as Number {
        if (binIndex >= 0 && binIndex < self.numBins) {
            return self.bins[binIndex];
        }
        return 0;
    }

    //! Get the bin index for a given grade value
    function getBinIndex(grade as Float) as Number {
        var binIndex = ((grade - self.minBin) / self.binSize).toNumber();
        if (binIndex < 0) { return 0; }
        if (binIndex >= self.numBins) { return self.numBins - 1; }
        return binIndex;
    }

    //! Get the central grade value for a given bin index
    function getGradeForBin(binIndex as Number) as Float {
        if (binIndex >= 0 && binIndex < self.numBins) {
            return self.minBin + binIndex * self.binSize + self.binSize / 2.0;
        }
        return 0.0;
    }

    //! Compute and store the histogram statistics
    function compute() {
        if (self.totalCount == 0) { return; }

        computedSampledBinRange = getSampledBinRange();

        if (computedSampledBinRange[0] > 21) { computedSampledBinRange[0] = 21; }
        if (computedSampledBinRange[1] < 28) { computedSampledBinRange[1] = 28; }

        computedHistogramForRange = getHistogramForRange(computedSampledBinRange);
        
        computed = true;
    }

    function getTotalCount() as Number {
        return self.totalCount;
    }

    function getBinSize() as Float {
        return self.binSize;
    }

    function getNumBins() as Number {
        return self.numBins;
    }

    private function getNormalizedHistogram() as Array {
        var result = new [numBins];
        for (var i = 0; i < self.numBins; i++) {
            result[i] = self.bins[i].toFloat() / self.totalCount; // Normalize to fraction
        }
        return result;
    }

    private function getSampledBinRange() as Array {
        var minSampled = -1;
        var maxSampled = -1;
        for (var i = 0; i < self.numBins; i++) {
            if (self.bins[i] > 0) {
                if (minSampled == -1) { minSampled = i; }
                maxSampled = i;
            }
        }
        return [minSampled, maxSampled];
    }

    private function getHistogramForRange(range as Array) as Array {
        var result = new [0];
        for (var i = range[0]; i <= range[1]; i++) {
            result.add(self.bins[i].toFloat() / self.totalCount);
        }
        return result;
    }

    function reset() {
        for (var i = 0; i < numBins; i++) {
            self.bins[i] = 0;
        }
        self.totalCount = 0;
    }

    //! Return the grade at which `percent` of the samples are at or above that grade.
    //! Uses linear interpolation within the enclosing bin. Percent is expressed 0-100.
    public function getHighGrade(percent as Float) as Float {
        if (self.totalCount == 0) { return 0.0; }

        var pct = percent;

        // If out of bounds, return extremes of sampled range converted to grades
        var range = getSampledBinRange();
        if (pct <= 0.0) { return self.getGradeForBin(range[1]); }
        if (pct >= 100.0) { return self.getGradeForBin(range[0]); }

        var total = self.totalCount;
        var target = total * (pct / 100.0);
        var cumulative = 0.0;

        for (var i = self.numBins - 1; i >= 0; i--) {
            var binCount = self.bins[i].toFloat();
            if (binCount <= 0.0) { continue; }

            var cumulativeAbove = cumulative;
            cumulative += binCount;

            if (cumulative >= target) {
                var binLower = self.minBin + i * self.binSize;
                var binUpper = binLower + self.binSize;

                var countNeeded = target - cumulativeAbove;
                if (countNeeded < 0.0) { countNeeded = 0.0; }
                else if (countNeeded > binCount) { countNeeded = binCount; }

                var fractionInBin = countNeeded / binCount;
                return binUpper - fractionInBin * self.binSize;
            }
        }

        return self.minBin;
    }

    public function getHighGradeForTime(seconds as Float) as Float {
        if (self.totalCount == 0) { return 0.0; }

        var percent = (seconds.toFloat() / totalCount) * 100.0;

        return getHighGrade(percent);
    }

}
