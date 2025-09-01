// ClimbTracker.mc
// Tracks climb stats for individual climbs
// Usage: create an instance, call update() with each new sample
// Use .getClimbs() to get finished climbs

import Toybox.Lang;

class ClimbTracker {
    // Configurable thresholds
    static var minGrade = 0.03;         // Minimum grade to start climb (3%)
    static var minAscent = 8.0;         // Minimum ascent (meters) to start climb
    static var minDist = 100.0;         // Minimum distance (meters) to start climb
    static var nonClimbEndFrac = 0.2;   // Fraction of ascent descent to end climb
    static var nonClimbEndBase = 100.0; // Base distance for non-climb end condition
    static var sampleMargin = 3;        // Sample margin
    static var minClimbLength = 100;    // Samples required to consider a climb valid
    static var minClimbAscent = 10;    // Samples required to consider a climb valid
    static var gradeFraction = 0.33; // Fraction of minGrade to consider as uphill

    // State for current climb
    private var climbActive = false;
    private var startAlt = 0.0;
    private var startTime = 0.0;
    private var totalTime = 0.0;
    private var ascent = 0.0;
    private var totalDist = 0.0;
    private var maxGrade = 0.0;    
    private var climbSumGrade = 0.0;
    private var climbSamples = 0;
    private var uphillDist = 0.0;
    private var uphillTime = 0.0;
    private var descent = 0.0;
    private var totalSamples = 0;
    private var flatDist = 0.0;
    private var downhillDist = 0.0;
    private var climbLastAlt = 0.0;
    private var lastTime = 0.0;
    
    // Pause counters for look-back logic (descent and plateau)
    private var downhillDistBuffer = 0.0;
    private var flatDistBuffer = 0.0;
    private var flatElevationGain = 0.0;
    private var flatElevationLoss = 0.0;
    private var endDetectionBuffer = 0.0; // Buffer for end detection logic

    // Finished climbs
    var climbs = [];

    function isClimbActive() { return (climbActive && totalSamples > minClimbLength); }

    function nonClimbDistBuffer() { return downhillDistBuffer + flatDistBuffer; }

    function initialize(_minGrade as Float) {
        self.minGrade = _minGrade;
    }

    function update(altitude as Float, delta_distance as Float, grade as Float, time as Float) {
        if (!climbActive) {
            // Detect climb start
            if (grade >= minGrade) {
                startAlt = altitude;
                startTime = time;
                climbLastAlt = altitude;
                uphillTime = 0.0;
                lastTime = time;
                ascent = 0.0;
                
                totalDist = 0.0;
                uphillDist = 0.0;
                flatDist = 0.0;
                downhillDist = 0.0;

                maxGrade = grade;
                climbSumGrade = 0.0;
                climbSamples = 0;
               
                descent = 0.0;
                totalSamples = 0;
                flatDist = 0.0;
                flatElevationGain = 0.0; // Reset non uphill elevation gain tracker
                flatElevationLoss = 0.0;
                flatDistBuffer = 0.0;
                downhillDistBuffer = 0.0;
                endDetectionBuffer = 0.0;

                climbActive = true;

                System.println("CLIMB STARTED #" + climbs.size());
            }
        } 
        else {
            // Update climb stats or buffer
            var dAlt = altitude - climbLastAlt;
            var dTime = time - lastTime;
            var segmentType = "";

            totalSamples++;

            if ((grade > minGrade * gradeFraction && endDetectionBuffer < nonClimbEndBase) || grade > minGrade) { 
                // Uphill
                uphillDist += delta_distance;
                ascent += dAlt;
                climbSumGrade += grade;
                climbSamples++;
                uphillTime += dTime;
                totalDist += delta_distance;
                
                totalTime = time - startTime;
                if (grade > maxGrade) { maxGrade = grade; }
                segmentType = "UPHILL";

                if (grade > minGrade && endDetectionBuffer < nonClimbEndBase) {
                    // We are back at climbing grades and have been climbing enough to consider we are on the same hill
                    // Flush the buffer
                    System.println("FLUSHING BUFFER");
                    totalDist += flatDistBuffer;        // Add float to total distance
                    totalDist += downhillDistBuffer;    // Add descent to total distance
                    downhillDist += downhillDistBuffer; // Add any downhill distance from flat and descending segments
                    flatDist += flatDistBuffer;         // Add flat distance from "flat" segments
                    ascent += flatElevationGain;        // Add elevation gain from "flat" segments
                    descent += flatElevationLoss;       // Add descent elevation change
                    
                    // Reset the non uphill trackers
                    downhillDistBuffer = 0.0;
                    flatDistBuffer = 0.0;
                    flatElevationGain = 0.0;            
                    flatElevationLoss= 0.0;
                }

                // "Reset" end detection buffer
                endDetectionBuffer *= 0.95;  
            } 
            else if (grade < -minGrade * gradeFraction) {
                // Descent
                downhillDistBuffer += delta_distance;
                endDetectionBuffer += delta_distance;
                flatElevationLoss += dAlt.abs();
                segmentType = "DESCNT";
            } 
            else {
                // Flat
                flatDistBuffer += delta_distance;
                endDetectionBuffer += delta_distance;
                segmentType = " FLAT ";

                if (dAlt > 0) { flatElevationGain += dAlt; }
                else { flatElevationLoss += dAlt.abs(); }
            }

            climbLastAlt = altitude;
            lastTime = time;
            var avgClimbingGrade = uphillDist > 0 ? climbSumGrade / climbSamples : 0.0;
            
            // Print single-line status
            System.println("TIME " + totalTime.format("%.1f") + 
                "s | " + (grade * 100).format("%+.1f") +
                "% | " + segmentType + 
                " █ " + totalDist.format("%d") + 
                "m | " + ascent.format("%.1f") +
                "m █ ↑ " + uphillDist.format("%d") + 
                "m | → " + flatDist.format("%d") + 
                "m | ↓ " + downhillDist.format("%d") + 
                "m | ⇥ " + endDetectionBuffer.format("%d") + 
                "m | avg% " + (avgClimbingGrade * 100).format("%.2f") + "%");

            // End climb condition check
            if (totalSamples > sampleMargin && ascent < minClimbAscent) { 
                // We are not really climbing yet, discard if anything is downhill or if flat distance is longer than climb distance
                if (flatElevationLoss > nonClimbEndFrac * ascent || endDetectionBuffer > totalDist) { discardCurrentClimb(); }
            }
            else if (uphillDist > minClimbLength) { 
                // We are climbing, figure out if climb is over
                if (endDetectionBuffer >= nonClimbEndFrac * uphillDist + nonClimbEndBase) { saveClimb(); }
            }
        }
    }

    function discardCurrentClimb() {
        climbActive = false;
        var avgClimbingGrade = uphillDist > 0 ? climbSumGrade / climbSamples : 0.0;
        System.println("CLIMB DISCARDED" + 
            "\n startTime: " + startTime + 
            "\n startAlt: " + startAlt + 
            "\n ascent: " + ascent + 
            "\n distance: " + totalDist + 
            "\n avgGrade: " + avgClimbingGrade +
            "\n uphillDist: " + uphillDist +
            "\n flatDist: " + flatDist +
            "\n downhillDist: " + downhillDist +
            "\n maxGrade: " + maxGrade);
    }

    public function saveClimb() {
        var uphillAverageGrade = uphillDist > 0 ? climbSumGrade / climbSamples : 0.0;
        
        climbs.add({
            "startTime" => startTime,
            "totalTime" => totalTime,
            "uphillTime" => uphillTime,

            "totalDist" => totalDist,   // Total distance including flat and descents
            "uphillDist" => uphillDist, // Actual distance going uphill at gradients higher than half minGrade
            "flatDist" => flatDist,
            "downhillDist" => downhillDist,
            
            "startAlt" => startAlt,
            "ascent" => ascent,         // How many meters gained
            "descent" => descent,       // How many meters decended
            "avgGrade" => uphillAverageGrade, // Time averaged grade during uphill
            "maxGrade" => maxGrade,
        });

        System.println("CLIMB " + climbs.size().format("%d") + " COMPLETE");
        System.println(getLastClimb());

        climbActive = false;
    }

    function getClimbs() {
        return climbs;
    }

    function getLastClimb() {
        if (climbs.size() > 0) {
            return climbs[climbs.size() - 1];
        } 
        else {
            return null;
        }
    }

    function reset() {
        climbs = [];
        climbActive = false;
    }
}
