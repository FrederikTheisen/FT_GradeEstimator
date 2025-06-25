import Toybox.Activity;
import Toybox.Lang;
import Toybox.Time;
import Toybox.WatchUi;
import Toybox.FitContributor;

class GradeEstimatorView extends WatchUi.SimpleDataField {
    // CONFIG
    const SAMPLE_WINDOW      = 6;       // seconds
    const EMA_ALPHA          = 0.25;    // smoothing factor
    const EMA_ALT_ALPHA      = 0.33;    // altitude effect
    const THRESHOLD_LIGHT    = 5.0;     // percent
    const THRESHOLD_STEEP    = 10.0;    // percent
    const FIELD_ID_GRADE     = 30;      // EMA grade, REC
    const FIELD_ID_LIGHT     = 31;      // meters ≥ 5%, SESSION
    const FIELD_ID_STEEP     = 32;      // meters ≥10%, SESSION
    const FIELD_ID_MAXGRADE  = 33;      // max grade,   SESSION
    const MAX_ALT_JUMP       = 5;

    const buffer_str        = "|";
    const blank_str         = "-.-";
    const suffix            = "%";
    const str_format        = "%+.1f";

    // STATE
    var buffer as Array        = [SAMPLE_WINDOW];   // last {altitude, distance}
    var bufIndex as Number     = 0;
    var accWinDist as Float    = 0.0;  // over window
    var emaValue as Float      = 0.0;  // fraction, e.g. 0.05 = 5%
    var distLight as Float     = 0.0;  // meters at ≥5%
    var distSteep as Float     = 0.0;  // meters at ≥10%
    var maxGrade as Float      = 0.0;  // maximum grade encountered
    var bufFull as Boolean     = false;
    var lastSample as Number   = 0;

    // FIT FIELDS
    var gradeField, lightField, steepField, maxField;

    function getBufferString() as String {
        var str = "";
        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            if (i < bufIndex) { str += "|"; }
            else { str += "."; }
        }
        str += "";

        return str;
    }

    function initialize() {
        SimpleDataField.initialize();

        label = "Grade";

        // Per-second EMA grade
        gradeField = createField(
            "ft_grade", FIELD_ID_GRADE,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_RECORD, :units=>"%" }
        );
        gradeField.setData(0.0);

        // Session totals
        lightField = createField(
            "dist_5pct", FIELD_ID_LIGHT,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_SESSION, :units=>"m"}
        );
        lightField.setData(0.0);

        steepField = createField(
            "dist_10pct", FIELD_ID_STEEP,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_SESSION, :units=>"m"}
        );
        steepField.setData(0.0);

        maxField = createField(
            "grade_max", FIELD_ID_MAXGRADE,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_SESSION, :units=>"%"}
        );
        maxField.setData(0.0);

        // Initialize rolling buffer
        buffer     = new [SAMPLE_WINDOW];
        bufIndex   = 0;
        accWinDist  = 0.0;
        emaValue   = 0.0;
        distLight  = 0.0;
        distSteep  = 0.0;
    }

    function compute(info) {
        // Assume exactly 1 Hz
        var speed    = info.currentSpeed;
        var altitude = info.altitude;
        var distSec  = speed * 1.0;
        var eDist = info.elapsedDistance;
        var eTime = info.elapsedTime / 1000;

        if (speed == null || eDist == null || altitude == null) { return blank_str; }

        // Reset if nearly stopped
        if (speed < 1.0 || eTime > lastSample + 1.1) {
            _resetAll();
            gradeField.setData(0.0);
            lastSample = eTime;
            return blank_str;
        }

        lastSample = eTime;

        // Update rolling window
        if (bufFull) { accWinDist -= buffer[bufIndex]["distance"]; }            // Remove oldest distance
        buffer[bufIndex] = { "altitude" => altitude, "distance" => distSec };   // Replace oldest sample
        accWinDist += distSec;                                                  // Accumulate distance with current movement
        bufIndex = (bufIndex + 1) % SAMPLE_WINDOW;                              // Iterate rolling buffer index

        if (bufIndex == 0) { bufFull = true; } // Buffer full

        System.println(eTime.format("%d") + "s | " + eDist.format("%.1f") + "m | " + altitude.format("%.2f") + "m | " + bufIndex.format("%d"));

        if (accWinDist < 5 || !bufFull) {
            gradeField.setData(0.0);
            return getBufferString();
        }

        var prevIdx   = (bufIndex - 1 + SAMPLE_WINDOW) % SAMPLE_WINDOW;
        var prevAlt   = buffer[prevIdx]["altitude"];
        if (prevAlt != null && (altitude - prevAlt).abs() > MAX_ALT_JUMP) {
            System.println("Alt jump of " + (altitude - prevAlt) + "m exceeds " + MAX_ALT_JUMP + "m — resetting buffer");
            _resetAll();
            gradeField.setData(0.0);
            return blank_str;
    }

        // Compute raw & EMA grade
        var oldestIdx = bufIndex;
        var dh = altitude - buffer[oldestIdx]["altitude"];
        var grade_raw = dh / accWinDist;
        var delta = emaValue - grade_raw;

        System.println(" - speed:      " + speed.format("%.2f") + "m/s | " + (speed*3.6).format("%.1f") + "kmh");
        System.println(" - acc dist:   " + accWinDist.format("%.3f"));
        System.println(" - elev gain:  " + dh.format("%.2f"));
        System.println(" - grade:      " + (100*grade_raw).format("%.3f"));

        if (delta.abs() > 0.05) {
            if (delta > 0) { grade_raw = emaValue - 0.05; }
            else { grade_raw = emaValue + 0.05; }
        }

        var alpha = EMA_ALPHA + EMA_ALT_ALPHA * dh.abs() / (1 + dh.abs());

        emaValue = alpha * grade_raw + (1 - alpha) * emaValue;

        System.println(" - ema grade:  " + (100*emaValue).format("%.3f"));

        // Accumulate distance in each zone
        var pctGrade = emaValue * 100.0;
        if (pctGrade >= THRESHOLD_LIGHT) { distLight += distSec; }
        if (pctGrade >= THRESHOLD_STEEP) { distSteep += distSec; }
        if (pctGrade > maxGrade) { maxGrade = pctGrade; }

        // Format & export
        var value = pctGrade.format(str_format) + suffix;
        gradeField.setData(pctGrade);

        // Update session summary fields
        lightField.setData(distLight);
        steepField.setData(distSteep);
        maxField.setData(maxGrade); 

        System.println(" - max grade:  " + maxGrade.format("%.3f"));
        System.println(" - dist 5pct:  " + distLight.format("%.3f"));
        System.println(" - dist 10pct: " + distSteep.format("%.3f"));

        return value;
    }

    hidden function _resetAll() {
        accWinDist   = 0.0;
        bufIndex = 0;
        bufFull = false;
    }
}