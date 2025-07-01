import Toybox.Activity;
import Toybox.Lang;
import Toybox.Time;
import Toybox.WatchUi;
import Toybox.FitContributor;
import Toybox.Graphics;
import Toybox.Application;


class GradeEstimatorView extends WatchUi.DataField {
    // CONFIG
    const SAMPLE_WINDOW      = 11;       // seconds
    const EMA_ALPHA          = 0.25;    // smoothing factor
    const EMA_ALT_ALPHA      = 0.5;    // altitude effect
    const THRESHOLD_LIGHT    = 5.0;     // percent
    const THRESHOLD_STEEP    = 10.0;    // percent
    const FIELD_ID_GRADE     = 30;      // grade, REC
    const FIELD_ID_LIGHT     = 31;      // meters ≥ 5%, SESSION
    const FIELD_ID_STEEP     = 32;      // meters ≥10%, SESSION
    const FIELD_ID_MAXGRADE  = 33;      // max grade,   SESSION
    const FIELD_ID_VAM_GRAPH = 34;      // grade, REC
    const FIELD_ID_VAM_AVG   = 35;      // grade, REC
    const MAX_ALT_JUMP       = 10;

    const buffer_str        = "|";
    const blank_str         = "-.-";
    const suffix            = "%";
    const str_format        = "%+.1f";
    const vam_str_format        = "%d";

    var vamUnit as String = "";

    // STATE
    var buffer as Array<Dictionary> = [];
    var rawAltitudes as Array<Float> = [];
    var bufIndex as Number     = 0;
    var accWinDist as Float    = 0.0;  // over window
    var grade as Float         = 0.0;  // fraction, e.g. 0.05 = 5%
    var distLight as Float     = 0.0;  // meters at ≥5%
    var distSteep as Float     = 0.0;  // meters at ≥10%
    var maxGrade as Float      = 0.0;  // maximum grade encountered
    var bufFull as Boolean     = false;
    var lastSample as Number   = 0;
    var vam as Float           = 0.0;  // VAM in m/h
    var vamAvg as Float        = 0.0;  // Average VAM in m/h

    var sumAscentVam as Float   = 0.0; // Sum of ascenting VAM (+5%)
    var samplesAscent as Number = 0; // Number of samples with ascenting VAM

    var kf as AltitudeGradientKalman or Null;
    var kf_grade               = 0.0;

    // FIT FIELDS
    var vamField, vamAvgField, gradeField, lightField, steepField, maxField;

    // UI
    var shouldDrawVam as Boolean = false;
    var textColor as Number      = Graphics.COLOR_WHITE;

    // STATUS STATE
    var calculating as Boolean  = false;
    var quality as Float        = 0.0;

    function getBufferString() as String {
        var str = "";
        for (var i = 0; i < SAMPLE_WINDOW; i += 1) {
            if (i < bufIndex) { str += "|"; }
            else { str += "."; }
        }
        str += "";

        return str;
    }

    function getPausedString() as String {
        return "|||" + (100*grade).format(str_format) + suffix + "|||";
    }

    // Helper: median of three values
    function median3(a, b, c) {
        if ((a <= b && b <= c) || (c <= b && b <= a)) { return b; }
        if ((b <= a && a <= c) || (c <= a && a <= b)) { return a; }
        return c;
    }

    function getStatusString() as String {
        var c = "";
        if (calculating) {
            c = "ACTIVE";
            c += " |";
            for (var i = 0; i < 10; i++)
            {
                if (i < quality) {
                    c += "█";
                } else {
                    c += "░";
                }
            } 
            c += "|";
        } else if (bufIndex > 0) {
            c = "BUFFERING";
            //c += getBufferString();
        }
        else {
            c = "NO DATA";
        }
        return c;
    }

    function initialize() {
        DataField.initialize();

        vamUnit = WatchUi.loadResource(Rez.Strings.Unit_VAM);

        // Per-second grade
        gradeField = createField(
            WatchUi.loadResource(Rez.Strings.GC_ChartTitle_Grade), FIELD_ID_GRADE,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_RECORD, :units=>WatchUi.loadResource(Rez.Strings.Unit_Grade) }
        );
        gradeField.setData(0.0);

        vamField = createField(
            WatchUi.loadResource(Rez.Strings.GC_ChartTitle_VAM), FIELD_ID_VAM_GRAPH,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_RECORD, :units=>WatchUi.loadResource(Rez.Strings.Unit_VAM) }
        );
        vamField.setData(0.0);

        // Session totals
        lightField = createField(
            WatchUi.loadResource(Rez.Strings.GC_Label_Distance_Light), FIELD_ID_LIGHT,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_SESSION, :units=>WatchUi.loadResource(Rez.Strings.Unit_Distance)}
        );
        lightField.setData(0.0);

        steepField = createField(
            WatchUi.loadResource(Rez.Strings.GC_Label_Distance_Steep), FIELD_ID_STEEP,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_SESSION, :units=>WatchUi.loadResource(Rez.Strings.Unit_Distance)}
        );
        steepField.setData(0.0);

        maxField = createField(
            WatchUi.loadResource(Rez.Strings.GC_Label_Grade_Max), FIELD_ID_MAXGRADE,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_SESSION, :units=>WatchUi.loadResource(Rez.Strings.Unit_Grade)}
        );
        maxField.setData(0.0);

        vamAvgField = createField(
            WatchUi.loadResource(Rez.Strings.GC_Label_AverageVAM), FIELD_ID_VAM_AVG,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_SESSION, :units=>WatchUi.loadResource(Rez.Strings.Unit_VAM)}
        );
        vamAvgField.setData(0.0);

        // Initialize rolling buffer
        buffer = [];
        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            buffer.add({ "altitude" => 0.0, "distance" => 0.0 });
        }
        rawAltitudes = [];
        _resetAll();
        grade      = 0.0;
        distLight  = 0.0;
        distSteep  = 0.0;
    }

    // Layout overridden; drawing will be done in onUpdate dynamically
    function onLayout(dc as Dc) as Void  {
        var width_view = dc.getWidth();
        var width_device = System.getDeviceSettings().screenWidth;

        if (width_view < width_device - 10) {
            View.setLayout(Rez.Layouts.SmallLayout(dc));
        }
        else {
            View.setLayout(Rez.Layouts.WideLayout(dc));
            shouldDrawVam = true;
        }
    }

    function compute(info) {
        // Assume exactly 1 Hz
        var speed    = (info has :currentSpeed) ? info.currentSpeed : null;
        var altitude = (info has :altitude) ? info.altitude : null;
        var eTime = (info has :elapsedTime) ? info.elapsedTime / 1000 : 0;

        if (speed == null || altitude == null) { return blank_str; }

        // Reset if nearly stopped
        if (speed < 1.0 || eTime > lastSample + 1.1) {
            _resetAll();
            gradeField.setData(0.0);
            lastSample = eTime;
            return blank_str;
        }

        lastSample = eTime;

        // Median filter for altitude using only real raw values
        rawAltitudes.add(altitude);
        if (rawAltitudes.size() > 3) { rawAltitudes = rawAltitudes.slice(1, rawAltitudes.size()); }
        var medianAlt;
        if (rawAltitudes.size() == 3) {
            medianAlt = median3(rawAltitudes[0], rawAltitudes[1], rawAltitudes[2]);
        } else {
            medianAlt = altitude;
        }

        // Update rolling window 
        buffer[bufIndex] = { "altitude" => medianAlt, "distance" => speed };   // Replace oldest sample
        accWinDist += speed;                                                  // Accumulate distance with current movement
        bufIndex = (bufIndex + 1) % SAMPLE_WINDOW;                              // Iterate rolling buffer index
        accWinDist -= buffer[bufIndex]["distance"];

        if (bufIndex == 0) { bufFull = true; } // Buffer full, begin calculating slope

        if (accWinDist < 5 || !bufFull) {
            gradeField.setData(0.0);
            return blank_str;
        }

        // Compute raw & EMA grade
        var dh = altitude - buffer[bufIndex]["altitude"];
        var grade_raw = dh / accWinDist;

        if (dh.abs() > MAX_ALT_JUMP) {
            // If altitude jump is too large, reset buffer and start over
            _resetAll();
            gradeField.setData(0.0);
            return blank_str;
        }
        
        computeLinearRegressionSlope(buffer);
        
        //  System.println(" - speed:      " + speed.format("%.2f") + "m/s | " + (speed*3.6).format("%.1f") + "kmh");
        //  System.println(" - acc dist:   " + accWinDist.format("%.3f"));
        //  System.println(" - elev gain:  " + dh.format("%.2f"));
        //  System.println(" - raw grade:  " + (100*grade_raw).format("%.3f"));
        //  System.println(" - grade:      " + (100*grade).format("%.3f"));

        // Accumulate distance in each zone
        var pctGrade = grade * 100.0;
        if (pctGrade >= THRESHOLD_LIGHT) { distLight += speed; }
        if (pctGrade >= THRESHOLD_STEEP) { distSteep += speed; }
        if (pctGrade > maxGrade) { maxGrade = pctGrade; }

        // Format & export
        var value = pctGrade.format(str_format) + suffix;
        gradeField.setData(pctGrade);

        // Update session summary fields
        lightField.setData(distLight / 1000.0);
        steepField.setData(distSteep / 1000.0);
        maxField.setData(maxGrade); 

        //  System.println(" - max grade:  " + maxGrade.format("%.3f"));
        //  System.println(" - dist 5pct:  " + distLight.format("%.3f"));
        //  System.println(" - dist 10pct: " + distSteep.format("%.3f"));

        computeVAM(grade, buffer[bufIndex]["distance"]);

        return blank_str;
    }

    function computeEmaGrade(altitude) as Float {
        // Compute raw & EMA grade
        var dh = altitude - buffer[bufIndex]["altitude"];
        var grade_raw = dh / accWinDist;
        var alpha = EMA_ALPHA + EMA_ALT_ALPHA * dh.abs() / (1 + dh.abs());
        var ema_grade = alpha * grade_raw + (1 - alpha) * grade;

        return ema_grade;
    }

    function computeLinearRegressionSlope(samples as Array<Dictionary>) {
        var xVals = [];
        var dist = 0.0;

        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            var idx = (bufIndex + i) % SAMPLE_WINDOW;
            dist += samples[idx]["distance"];
            xVals.add(dist);
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
        }
        
        grade = (varX > 0.0) ? (covXY / varX) : 0.0;
        var rmsd = 0.0;
        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            var idx = (bufIndex + i) % SAMPLE_WINDOW;
            var measAltDelta = samples[idx]["altitude"] - meanY;
            var AltDelta = grade * (xVals[i] - meanX);
            var res = (AltDelta - measAltDelta);

            rmsd += res*res;
        }

        rmsd = rmsd / SAMPLE_WINDOW;
        var q = 1.0 / rmsd;
        quality = (varX > 0.0) ? 10 * (rmsd / (SAMPLE_WINDOW - 2)) : -1.0;

        System.println("residual: " + rmsd.format("%.3f") + " | data quality: " + quality.format("%.3f"));

        calculating = true;
    }

    function computeVAM(grade as Float, speed as Float) as Float {
        // Compute VAM based on grade and speed
        if (grade > 0.0 && speed > 0.0) {
            vam = speed * grade * 3600; // in m/h
        }
        else { vam = 0.0; }

        if (grade > 0.05) {
            // Accumulate VAM for ascenting segments
            sumAscentVam += vam;
            samplesAscent++;

            vamAvg = sumAscentVam / samplesAscent;
        }

        vamField.setData(vam);
        vamAvgField.setData(vamAvg);

        return vam;
    }

    function onUpdate(dc as Dc) as Void 
    {
        var background = View.findDrawableById("Background") as Text;
        background.setColor(getBackgroundColor());

        textColor = Graphics.COLOR_WHITE;
        if (getBackgroundColor() == Graphics.COLOR_WHITE) { textColor = Graphics.COLOR_BLACK;}

        setLabelColor(dc);

        drawDefaultView(dc);

        if (shouldDrawVam) {
            drawVAMFields(dc);
        }

        drawStatusLabel(dc);

        View.onUpdate(dc);
    }

    function drawDefaultView(dc as Dc) as Void {
        var value_curr_grade = View.findDrawableById("value_curr_grade") as Text;
        var value_max_grade = View.findDrawableById("value_max_grade") as Text;
        var value_light = View.findDrawableById("value_light") as Text;
        var value_steep = View.findDrawableById("value_steep") as Text;
        
        if (value_curr_grade != null)
        {
            value_curr_grade.setColor(textColor);
            value_curr_grade.setText((100 * grade).format(str_format) + suffix);
        }

        if (value_max_grade != null)
        {
            value_max_grade.setColor(textColor);
            value_max_grade.setText(maxGrade.format(str_format) + suffix);
        }

        if (value_light != null)
        {
            value_light.setColor(textColor);
            value_light.setText((distLight/1000).format("%.1f") + " km");
        }

        if (value_steep != null)
        {
            value_steep.setColor(textColor);
            value_steep.setText((distSteep/1000).format("%.1f") + " km");
        }
    }

    function drawVAMFields(dc as Dc) as Void {

        var background = View.findDrawableById("Background") as Text;
        background.setColor(getBackgroundColor());

        // Set text color
        var textColor = Graphics.COLOR_WHITE;
        if (getBackgroundColor() == Graphics.COLOR_WHITE) { textColor = Graphics.COLOR_BLACK; } 

        var value_vam = View.findDrawableById("value_vam") as Text;
        var value_vam_avg = View.findDrawableById("value_vam_avg") as Text;

        if (value_vam != null) {
            value_vam.setColor(textColor);
            value_vam.setText((vam).format(vam_str_format) + " m/h");
        }

        if (value_vam_avg != null) {
            value_vam_avg.setColor(textColor);
            value_vam_avg.setText((vamAvg).format(vam_str_format) + " m/h");
        }
    }

    function setLabelColor(dc as Dc) as Void {
        var labels = ["label_curr_grade", "label_max_grade", "label_light", "label_steep", "label_vam", "label_vam_avg"];
        for (var i = 0; i < labels.size(); i++) {
            var label = labels[i];

            // Find the labels by ID and set its color
            var labelDrawable = View.findDrawableById(label) as Text;
            if (labelDrawable != null) {
                labelDrawable.setColor(textColor);
            }
        }
    }

    function drawStatusLabel(dc as Dc) as Void {
        var statusLabel = View.findDrawableById("label_status") as Text;
        if (statusLabel != null) {
            statusLabel.setColor(textColor);
            statusLabel.setText(getStatusString());
        }
    }

    hidden function _resetAll() {
        accWinDist   = 0.0;
        bufIndex = 0;
        for (var i = 0; i < SAMPLE_WINDOW; i++) {
            buffer[i] = { "altitude" => 0.0, "distance" => 0.0 }; 
        }
        rawAltitudes = [];
        bufFull = false;
        calculating = false;
    }
}