import Toybox.Activity;
import Toybox.Lang;
import Toybox.Time;
import Toybox.WatchUi;
import Toybox.FitContributor;

class GradeEstimatorView extends WatchUi.SimpleDataField {
    // CONFIG
    const SAMPLE_WINDOW      = 9;       // seconds
    const EMA_ALPHA          = 0.25;    // smoothing factor
    const EMA_ALT_ALPHA      = 0.5;    // altitude effect
    const THRESHOLD_LIGHT    = 5.0;     // percent
    const THRESHOLD_STEEP    = 10.0;    // percent
    const FIELD_ID_GRADE     = 30;      // grade, REC
    const FIELD_ID_LIGHT     = 31;      // meters ≥ 5%, SESSION
    const FIELD_ID_STEEP     = 32;      // meters ≥10%, SESSION
    const FIELD_ID_MAXGRADE  = 33;      // max grade,   SESSION
    const FIELD_ID_GRADE_KF  = 35;      // grade, REC
    const MAX_ALT_JUMP       = 5;

    const buffer_str        = "|";
    const blank_str         = "-.-";
    const suffix            = "%";
    const str_format        = "%+.1f";

    // STATE
    var buffer as Array        = [SAMPLE_WINDOW];   // last {altitude, distance}
    var bufIndex as Number     = 0;
    var accWinDist as Float    = 0.0;  // over window
    var grade as Float         = 0.0;  // fraction, e.g. 0.05 = 5%
    var distLight as Float     = 0.0;  // meters at ≥5%
    var distSteep as Float     = 0.0;  // meters at ≥10%
    var maxGrade as Float      = 0.0;  // maximum grade encountered
    var bufFull as Boolean     = false;
    var lastSample as Number   = 0;

    var kf as AltitudeGradientKalman or Null;
    var kf_grade               = 0.0;

    // FIT FIELDS
    var gradeField_KF, gradeField, lightField, steepField, maxField;

    function getBufferString() as String {
        var str = "";
        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            if (i < bufIndex) { str += "|"; }
            else { str += ""; }
        }
        str += "";

        return str + (100*grade).format(str_format) + suffix + str;
    }

    function getPausedString() as String {
        return "<<" + (100*grade).format(str_format) + suffix + ">>";
    }

    function initialize() {
        SimpleDataField.initialize();

        label = WatchUi.loadResource(Rez.Strings.DisplayLabel_Gradient);

        // Per-second EMA grade
        gradeField = createField(
            WatchUi.loadResource(Rez.Strings.Label_Gradient_LinReg), FIELD_ID_GRADE,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_RECORD, :units=>WatchUi.loadResource(Rez.Strings.Unit_Grade) }
        );
        gradeField.setData(0.0);

        // gradeField_KF = createField(
        //     WatchUi.loadResource(Rez.Strings.Label_Gradient_Kalman), FIELD_ID_GRADE_KF,
        //     FitContributor.DATA_TYPE_FLOAT,
        //     {:mesgType=>FitContributor.MESG_TYPE_RECORD, :units=>WatchUi.loadResource(Rez.Strings.Unit_Grade) }
        // );
        // gradeField_KF.setData(0.0);

        // Session totals
        lightField = createField(
            WatchUi.loadResource(Rez.Strings.Label_Distance_Light), FIELD_ID_LIGHT,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_SESSION, :units=>WatchUi.loadResource(Rez.Strings.Unit_Distance)}
        );
        lightField.setData(0.0);

        steepField = createField(
            WatchUi.loadResource(Rez.Strings.Label_Distance_Steep), FIELD_ID_STEEP,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_SESSION, :units=>WatchUi.loadResource(Rez.Strings.Unit_Distance)}
        );
        steepField.setData(0.0);

        maxField = createField(
            WatchUi.loadResource(Rez.Strings.Label_Grade_Max), FIELD_ID_MAXGRADE,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_SESSION, :units=>WatchUi.loadResource(Rez.Strings.Unit_Grade)}
        );
        maxField.setData(0.0);

        // Initialize rolling buffer
        buffer = new [SAMPLE_WINDOW];
        _resetAll();
        grade      = 0.0;
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

        // if (kf == null) { kf = new AltitudeGradientKalman(altitude, 0, 0.01, 0.0005, 0.04); }

        // kf_grade = kf.update(speed, altitude)["estGrad"];

        // Reset if nearly stopped
        if (speed < 1.0 || eTime > lastSample + 1.1) {
            _resetAll();
            gradeField.setData(0.0);
            lastSample = eTime;
            return getPausedString();
        }

        lastSample = eTime;

        // Update rolling window 
        buffer[bufIndex] = { "altitude" => altitude, "distance" => distSec };   // Replace oldest sample
        accWinDist += distSec;                                                  // Accumulate distance with current movement
        bufIndex = (bufIndex + 1) % SAMPLE_WINDOW;                              // Iterate rolling buffer index
        accWinDist -= buffer[bufIndex]["distance"];                             // Remove oldest distance

        // System.println(eTime.format("%d") + "s | " + eDist.format("%.1f") + "m | " + altitude.format("%.2f") + "m | " + bufIndex.format("%d"));

        if (bufIndex == 0) { bufFull = true; } // Buffer full, begin calculating slope

        if (accWinDist < 5 || !bufFull) {
            gradeField.setData(0.0);
            return getBufferString();
        }

        // Compute raw & EMA grade
        var dh = altitude - buffer[bufIndex]["altitude"];
        var grade_raw = dh / accWinDist;
        
        grade = computeLinearRegressionSlope(buffer);
        
        // System.println(" - speed:      " + speed.format("%.2f") + "m/s | " + (speed*3.6).format("%.1f") + "kmh");
        // System.println(" - acc dist:   " + accWinDist.format("%.3f"));
        // System.println(" - elev gain:  " + dh.format("%.2f"));
        // System.println(" - raw grade:  " + (100*grade_raw).format("%.3f"));
        // System.println(" - grade:      " + (100*grade).format("%.3f"));

        // Accumulate distance in each zone
        var pctGrade = grade * 100.0;
        if (pctGrade >= THRESHOLD_LIGHT) { distLight += distSec; }
        if (pctGrade >= THRESHOLD_STEEP) { distSteep += distSec; }
        if (pctGrade > maxGrade) { maxGrade = pctGrade; }

        // Format & export
        var value = pctGrade.format(str_format) + suffix;
        gradeField.setData(pctGrade);
        // gradeField_KF.setData(kf_grade*100);

        // Update session summary fields
        lightField.setData(distLight / 1000.0);
        steepField.setData(distSteep / 1000.0);
        maxField.setData(maxGrade); 

        // System.println(" - max grade:  " + maxGrade.format("%.3f"));
        // System.println(" - dist 5pct:  " + distLight.format("%.3f"));
        // System.println(" - dist 10pct: " + distSteep.format("%.3f"));

        // System.println(eDist.format("%.1f") + "m | " + (100*grade).format("%.1f") + "% | " + (100*kf_grade).format("%.1f") + "%");

        return value;
    }

    function computeEmaGrade(altitude) as Float {
        // Compute raw & EMA grade
        var dh = altitude - buffer[bufIndex]["altitude"];
        var grade_raw = dh / accWinDist;
        var alpha = EMA_ALPHA + EMA_ALT_ALPHA * dh.abs() / (1 + dh.abs());
        var ema_grade = alpha * grade_raw + (1 - alpha) * grade;

        return ema_grade;
    }

    function computeLinearRegressionSlope(samples) {
        var xVals = [];
        var dist = 0.0;

        // var x_vals = "";
        // var y_vals = "";

        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            var idx = (bufIndex + i) % SAMPLE_WINDOW;
            dist += samples[idx]["distance"];
            xVals.add(dist);

            // x_vals += dist.format("%.2f") + ",";
        }

        var sumX = 0.0, sumY = 0.0;
        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            var idx = (bufIndex + i) % SAMPLE_WINDOW;
            sumY += samples[idx]["altitude"];
            sumX += xVals[i];
        }
        var meanX = sumX / SAMPLE_WINDOW;
        var meanY = sumY / SAMPLE_WINDOW;

        var covXY = 0.0, varX = 0.0;
        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            var idx = (bufIndex + i) % SAMPLE_WINDOW;
            var dx = xVals[i] - meanX;
            var dy = samples[idx]["altitude"] - meanY;
            covXY += dx * dy;
            varX += dx * dx;

            // y_vals += dy.format("%.2f") + ",";
        }

        // System.println(x_vals);
        // System.println(y_vals);

        return (varX > 0.0) ? (covXY / varX) : 0.0;
    }

    hidden function _resetAll() {
        accWinDist   = 0.0;
        bufIndex = 0;
        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            buffer[i] = { "altitude" => 0.0, "distance" => 0.0 }; 
        }
        bufFull = false;
    }
}